import Foundation
import Testing
@testable import AraCore

/// The first-run window's rules: whether it is shown at all, which step it is
/// on, and what that step says. All of it off-screen — the window itself only
/// draws what this decides.
@Suite("Setup flow")
struct SetupFlowTests {
    private static func state(microphone: MicrophonePermission = .granted,
                              accessibility: Bool = true,
                              modelPresent: Bool = true,
                              setupCompleted: Bool = true) -> SetupFlow.State {
        SetupFlow.State(microphone: microphone, accessibility: accessibility,
                        modelPresent: modelPresent, setupCompleted: setupCompleted)
    }

    // MARK: - whether the window appears

    @Test("a machine with everything in place never sees the window")
    func settledInstallSkipsSetup() {
        #expect(!SetupFlow.isNeeded(Self.state()))
        #expect(SetupFlow.step(Self.state()) == .done)
    }

    /// The flag covers the one thing that cannot be observed: whether the
    /// Core ML compile has ever finished. Nothing on disk answers that.
    @Test("a first launch with everything else in place still shows the window")
    func missingFlagShowsSetup() {
        #expect(SetupFlow.isNeeded(Self.state(setupCompleted: false)))
    }

    /// Read from live state rather than remembered, so revoking a permission
    /// brings the window back instead of a daemon that cannot work and cannot
    /// say why.
    @Test("a revoked permission brings the window back after setup finished")
    func revokedPermissionShowsSetupAgain() {
        #expect(SetupFlow.isNeeded(Self.state(microphone: .denied)))
        #expect(SetupFlow.isNeeded(Self.state(accessibility: false)))
    }

    @Test("a deleted model brings the window back")
    func missingModelShowsSetupAgain() {
        #expect(SetupFlow.isNeeded(Self.state(modelPresent: false)))
    }

    // MARK: - the order

    /// Permissions first, and the microphone before accessibility: without the
    /// microphone there is no dictation at all, while accessibility only stops
    /// the text reaching the cursor.
    @Test("the microphone comes first, then accessibility")
    func permissionsLeadInOrder() {
        #expect(SetupFlow.step(Self.state(microphone: .notDetermined,
                                          accessibility: false)) == .microphone)
        #expect(SetupFlow.step(Self.state(accessibility: false)) == .accessibility)
    }

    /// Nothing is downloaded before the permissions are settled. A user who
    /// abandons the window at the accessibility step has not been made to
    /// spend 1.6 GB of somebody's network on a daemon they cannot run.
    @Test("the download waits for both permissions")
    func downloadWaitsForPermissions() {
        #expect(SetupFlow.step(Self.state(microphone: .denied,
                                          modelPresent: false)) == .microphone)
        #expect(SetupFlow.step(Self.state(accessibility: false,
                                          modelPresent: false)) == .accessibility)
    }

    @Test("with the permissions granted and no model, the download is next")
    func downloadFollowsPermissions() {
        #expect(SetupFlow.step(Self.state(modelPresent: false,
                                          setupCompleted: false)) == .download)
    }

    /// The step this whole window exists for. Everything is present and
    /// granted, and the only thing left is the compile nobody can observe.
    @Test("with the model on disk and the flag unset, the compile is next")
    func prepareFollowsDownload() {
        #expect(SetupFlow.step(Self.state(setupCompleted: false)) == .prepare)
    }

    // MARK: - what each step says

    /// Every step says what is happening, including the two that are only
    /// waiting. A step with no words is a window that looks stuck.
    @Test("every step says what is happening")
    func everyStepSpeaks() {
        for step in SetupFlow.Step.allCases {
            let copy = SetupFlow.copy(for: step)
            #expect(!copy.title.isEmpty)
            #expect(!copy.detail.isEmpty)
        }
    }

    /// A button means "this step is waiting for you". The two that wait on
    /// macOS instead have none, because the only thing a button could do
    /// there is interrupt them.
    @Test("only the steps that wait for the user carry a button")
    func buttonsMarkTheUsersTurn() {
        #expect(SetupFlow.copy(for: .microphone).button != nil)
        #expect(SetupFlow.copy(for: .accessibility).button != nil)
        #expect(SetupFlow.copy(for: .done).button != nil)
        #expect(SetupFlow.copy(for: .download).button == nil)
        #expect(SetupFlow.copy(for: .prepare).button == nil)
    }

    /// The compile step runs for two and a half minutes with no progress to
    /// report, so its text is the only thing stopping a user from quitting —
    /// and quitting throws the whole compile away.
    @Test("the compile step says that quitting undoes it")
    func prepareWarnsAgainstQuitting() {
        let copy = SetupFlow.copy(for: .prepare)
        #expect(copy.detail.lowercased().contains("quit"))
        #expect(copy.button == nil)
    }

    /// It waits on macOS, not on the user, so offering a button would be
    /// offering a way to make it fail.
    @Test("the download step has nothing for the user to press")
    func downloadHasNoButton() {
        #expect(SetupFlow.copy(for: .download).button == nil)
    }

    /// The step no reading of the system can reach. macOS reports a granted
    /// accessibility permission the same way whether or not this process can
    /// use it, so only the user coming back from Settings marks the moment.
    @Test("the restart step is never derived from system state")
    func restartIsNeverDerived() {
        for microphone in [MicrophonePermission.granted, .denied, .notDetermined] {
            for accessibility in [true, false] {
                for modelPresent in [true, false] {
                    for completed in [true, false] {
                        #expect(SetupFlow.step(Self.state(
                            microphone: microphone, accessibility: accessibility,
                            modelPresent: modelPresent,
                            setupCompleted: completed)) != .restart)
                    }
                }
            }
        }
    }

    @Test("the restart step offers the restart")
    func restartOffersTheButton() {
        #expect(SetupFlow.copy(for: .restart).button != nil)
    }

    /// macOS only honours a fresh accessibility grant in a fresh process, so
    /// the step has to say that a restart is coming.
    @Test("the accessibility step explains the restart")
    func accessibilityExplainsTheRestart() {
        let copy = SetupFlow.copy(for: .accessibility)
        #expect(copy.detail.lowercased().contains("restart"))
    }
}
