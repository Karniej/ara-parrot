import Foundation
import Testing
@testable import AraCore

/// The one line the overlay pill shows while the daemon cannot dictate yet.
/// Two loads run concurrently and the pill has room for one sentence, so the
/// precedence between them is a decision — and decisions live in a pure
/// function, where a test can reach them without a screen.
@Suite("Warm-up status")
struct WarmupStatusTests {
    private static func status(
        transcriber: TranscriberWarmup?,
        formatter: WarmupStatus.Formatter = .notLoading
    ) -> WarmupStatus {
        WarmupStatus(modelID: "whisper-large-v3-turbo",
                     transcriber: transcriber, formatter: formatter)
    }

    @Test("a download with no percentage yet names the phase and the model")
    func downloadingIndeterminate() {
        #expect(Self.status(transcriber: .downloading(percent: nil)).message
                == "Downloading the speech model…")
    }

    @Test("a download with a percentage says it")
    func downloadingWithPercent() {
        #expect(Self.status(transcriber: .downloading(percent: 45)).message
                == "Downloading the speech model… 45%")
    }

    @Test("loading names the phase and the model")
    func loading() {
        #expect(Self.status(transcriber: .loading).message
                == "Loading the speech model…")
    }

    /// A load that has not returned in twenty seconds is not a load any more:
    /// it is Core ML compiling the model for the Neural Engine, which costs
    /// 2–3 minutes on whisper-large-v3-turbo and is thrown away entirely if
    /// the daemon is quit before it finishes. "loading…" for three minutes is
    /// what makes a user quit, so the line stops saying it.
    ///
    /// "once per macOS version" and not "one time": the ANE cache is keyed on
    /// the OS build, so a system update costs the compile again, and a promise
    /// the next update breaks is worse than no promise.
    @Test("a long load says what it is really doing")
    func preparingNeuralEngine() {
        let status = Self.status(transcriber: .preparingNeuralEngine)
        #expect(status.message == "Preparing the Neural Engine")
        // The headline alone would be a worse lie than the old long line: it
        // names the wait without bounding it. The detail is what keeps a user
        // from reading three minutes as a hang and quitting.
        #expect(status.detail == "one-time for this macOS version · a few minutes")
    }

    /// The split itself: a headline short enough to render, and the
    /// particulars one size down rather than truncated off the end.
    @Test("loading states put the model id in the detail, not the headline")
    func detailCarriesTheModel() {
        for phase: TranscriberWarmup in [.loading, .downloading(percent: nil),
                                         .downloading(percent: 45)] {
            let status = Self.status(transcriber: phase)
            #expect(status.detail == "whisper-large-v3-turbo")
            #expect(!(status.message ?? "").contains("whisper-large-v3-turbo"))
        }
    }

    @Test("a formatter-only wait has nothing to add below the headline")
    func formatterHasNoDetail() {
        #expect(Self.status(transcriber: nil, formatter: .loading).detail == nil)
    }

    /// It is still the load that gates dictation; only the wording changed.
    @Test("preparing the Neural Engine still holds dictation back")
    func preparingBlocks() {
        #expect(Self.status(transcriber: .preparingNeuralEngine).blocksDictation)
        #expect(Self.status(transcriber: .preparingNeuralEngine).isWarming)
    }

    /// The transcriber is the one that gates dictation, so while it is in
    /// flight it owns the line — the formatting model loads inside its shadow
    /// and has nothing to add.
    @Test("the transcriber's phase outranks the formatter's")
    func transcriberWins() {
        #expect(Self.status(transcriber: .loading, formatter: .loading).message
                == "Loading the speech model…")
    }

    @Test("once the transcriber is warm the formatter gets the line")
    func formatterAfterTranscriber() {
        #expect(Self.status(transcriber: nil, formatter: .loading).message
                == "Preparing the cleanup model…")
    }

    /// Nothing left to wait for is spelled `nil`, not an empty string: the
    /// caller's "is the daemon still warming up?" question and its "what do I
    /// put in the pill?" question have to have the same answer, or a press
    /// lands in the gap between them.
    @Test("nothing to wait for is no message, and not warming")
    func done() {
        for formatter in [WarmupStatus.Formatter.ready, .notLoading] {
            let status = Self.status(transcriber: nil, formatter: formatter)
            #expect(status.message == nil)
            #expect(!status.isWarming)
        }
    }

    @Test("any phase in flight is warming")
    func warming() {
        #expect(Self.status(transcriber: .downloading(percent: nil)).isWarming)
        #expect(Self.status(transcriber: .loading).isWarming)
        #expect(Self.status(transcriber: nil, formatter: .loading).isWarming)
    }

    /// An engine that never consults the formatting model must not make the
    /// user wait on a line about it — `rules`, `apple` and `off` skip the load
    /// entirely, and the status has to say the same thing the daemon does.
    @Test("a formatter that is not being loaded is never mentioned")
    func formatterNotLoading() {
        #expect(Self.status(transcriber: nil, formatter: .notLoading).message == nil)
    }

    /// The last frame of the warm-up, for the case where the user is holding
    /// the key at the moment it finishes: the pill has to stop saying
    /// "loading" without simply vanishing under their thumb.
    @Test("the ready line names the key that now works")
    func readyLine() {
        #expect(WarmupStatus.readyMessage(hotkeyLabel: "fn")
                == "ready — hold fn to dictate")
    }
}

@Suite("WarmupGate")
struct WarmupGateTests {
    /// The change this pins: dictation waited on *both* models, but only the
    /// transcriber can actually produce text. The formatting model is polish —
    /// `MLXFormatter.format` throws `.unavailable` until it loads and the chain
    /// falls through to the rules floor — so holding the hotkey shut through
    /// its load bought nothing and cost the user seconds of standing there.
    @Test("a loading formatter does not hold dictation back")
    func formatterDoesNotGateDictation() {
        let status = WarmupStatus(modelID: "whisper-base.en",
                                  transcriber: nil, formatter: .loading)
        #expect(!status.blocksDictation)
        // It still has something to say — the pill and menu line stay honest.
        #expect(status.message == "Preparing the cleanup model…")
    }

    @Test("a loading transcriber does hold dictation back")
    func transcriberGatesDictation() {
        for phase: TranscriberWarmup in [.loading, .downloading(percent: nil), .downloading(percent: 40)] {
            let status = WarmupStatus(modelID: "whisper-large-v3-turbo",
                                      transcriber: phase, formatter: .ready)
            #expect(status.blocksDictation, "\(phase) should gate dictation")
        }
    }

    @Test("nothing loading gates nothing and says nothing")
    func readyGatesNothing() {
        let status = WarmupStatus(modelID: "whisper-base.en",
                                  transcriber: nil, formatter: .ready)
        #expect(!status.blocksDictation)
        #expect(status.message == nil)
    }
}

/// Which warm-up reports are allowed to replace which.
///
/// Every report reaches the main actor on its own `Task` and those arrive
/// unordered, so the daemon cannot simply assign what it is handed: a 45% that
/// lands after a 46% reads as a stall, and a `.loading` that lands after
/// `.preparingNeuralEngine` takes back the only sentence explaining why the
/// user is about to wait three minutes.
@Suite("Warm-up phase order")
struct TranscriberWarmupOrderTests {
    @Test("warm is terminal — nothing reopens it")
    func warmIsTerminal() {
        #expect(!TranscriberWarmup.advances(from: nil, to: .loading))
        #expect(!TranscriberWarmup.advances(from: nil, to: .downloading(percent: 10)))
        #expect(!TranscriberWarmup.advances(from: nil, to: nil))
    }

    @Test("becoming warm always advances")
    func becomingWarmAdvances() {
        #expect(TranscriberWarmup.advances(from: .loading, to: nil))
        #expect(TranscriberWarmup.advances(from: .preparingNeuralEngine, to: nil))
        #expect(TranscriberWarmup.advances(from: .downloading(percent: 3), to: nil))
    }

    /// The percentage filter, which the daemon used to spell out inline.
    @Test("a percentage never walks backwards")
    func percentIsMonotonic() {
        #expect(TranscriberWarmup.advances(from: .downloading(percent: 45),
                                           to: .downloading(percent: 46)))
        #expect(!TranscriberWarmup.advances(from: .downloading(percent: 46),
                                            to: .downloading(percent: 45)))
        #expect(!TranscriberWarmup.advances(from: .downloading(percent: 46),
                                            to: .downloading(percent: 46)))
        // The indeterminate report is the download's first frame, so it may
        // open one but never replace a number with "no idea".
        #expect(!TranscriberWarmup.advances(from: .downloading(percent: 46),
                                            to: .downloading(percent: nil)))
    }

    @Test("the download gives way to the load")
    func downloadToLoad() {
        #expect(TranscriberWarmup.advances(from: .downloading(percent: 99), to: .loading))
    }

    /// A percentage arriving after `.loading` is a hop left over from a
    /// download that has already finished. Showing it would park the pill on a
    /// stale number until the load returns.
    @Test("a stale percentage cannot reopen the download")
    func stalePercentIsIgnored() {
        #expect(!TranscriberWarmup.advances(from: .loading, to: .downloading(percent: 99)))
        #expect(!TranscriberWarmup.advances(from: .preparingNeuralEngine,
                                            to: .downloading(percent: 99)))
    }

    /// The repair, which is the case that must not be mistaken for one.
    ///
    /// `WhisperWarmupPlan.attempt` falls back to the hub when a model that
    /// passed `isPresent` fails to load — truncated `weight.bin`, most likely —
    /// and by then the pill has been on `.loading` since before the first
    /// attempt. The hub branch opens with `.downloading(percent: nil)`, which
    /// is emitted once and never carries a number, so it is the one report that
    /// means "we went back for the download" rather than "the download you
    /// already saw". Rejecting it runs a 1.6 GB re-download under the word
    /// "loading…", with no progress and no watchdog.
    @Test("the repair's opening frame reopens the download")
    func repairReopensTheDownload() {
        #expect(TranscriberWarmup.advances(from: .loading, to: .downloading(percent: nil)))
        #expect(TranscriberWarmup.advances(from: .preparingNeuralEngine,
                                           to: .downloading(percent: nil)))
    }

    /// End to end, the sequence a repair actually emits: the pill starts on
    /// `.loading` (the model looked present), the local load throws, the hub
    /// branch opens indeterminate, percentages climb, and the load resumes.
    /// Every step has to be shown or the download is invisible.
    @Test("a full repair sequence is shown at every step")
    func repairSequenceIsVisible() {
        var current: TranscriberWarmup? = .loading
        let reports: [TranscriberWarmup?] = [
            .downloading(percent: nil), .downloading(percent: 7),
            .downloading(percent: 63), .downloading(percent: 100),
            .loading, nil,
        ]
        var shown: [TranscriberWarmup?] = []
        for report in reports where TranscriberWarmup.advances(from: current, to: report) {
            current = report
            shown.append(report)
        }
        #expect(shown == reports)
    }

    /// The one this rule exists for. `.preparingNeuralEngine` is raised by a
    /// watchdog while the load is still inside `WhisperKit.init`; any
    /// `.loading` still in flight behind it must not undo it.
    @Test("the Neural Engine notice is not taken back")
    func preparingIsNotUndone() {
        #expect(TranscriberWarmup.advances(from: .loading, to: .preparingNeuralEngine))
        #expect(!TranscriberWarmup.advances(from: .preparingNeuralEngine, to: .loading))
        #expect(!TranscriberWarmup.advances(from: .preparingNeuralEngine,
                                            to: .preparingNeuralEngine))
    }

    /// …but a repair that starts *after* the notice went up is a real download,
    /// and the notice must give way to it — otherwise the pill claims the
    /// Neural Engine is being prepared for the length of a 1.6 GB fetch. The
    /// second attempt raises its own notice if it needs one.
    @Test("the Neural Engine notice gives way to a repair")
    func preparingGivesWayToRepair() {
        var current: TranscriberWarmup? = .preparingNeuralEngine
        for report: TranscriberWarmup in [.downloading(percent: nil), .downloading(percent: 40)] {
            #expect(TranscriberWarmup.advances(from: current, to: report))
            current = report
        }
        #expect(TranscriberWarmup.advances(from: current, to: .loading))
    }
}
