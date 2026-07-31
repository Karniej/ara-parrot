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
                == "downloading whisper-large-v3-turbo…")
    }

    @Test("a download with a percentage says it")
    func downloadingWithPercent() {
        #expect(Self.status(transcriber: .downloading(percent: 45)).message
                == "downloading whisper-large-v3-turbo… 45%")
    }

    @Test("loading names the phase and the model")
    func loading() {
        #expect(Self.status(transcriber: .loading).message
                == "loading whisper-large-v3-turbo…")
    }

    /// The transcriber is the one that gates dictation, so while it is in
    /// flight it owns the line — the formatting model loads inside its shadow
    /// and has nothing to add.
    @Test("the transcriber's phase outranks the formatter's")
    func transcriberWins() {
        #expect(Self.status(transcriber: .loading, formatter: .loading).message
                == "loading whisper-large-v3-turbo…")
    }

    @Test("once the transcriber is warm the formatter gets the line")
    func formatterAfterTranscriber() {
        #expect(Self.status(transcriber: nil, formatter: .loading).message
                == "preparing the formatting model…")
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
        #expect(status.message == "preparing the formatting model…")
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
