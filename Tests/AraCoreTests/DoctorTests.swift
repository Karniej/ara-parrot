import Foundation
import Testing
@testable import AraCore

/// The spec's error-handling table requires an unavailable on-device model to be
/// "surfaced once in `doctor`". It is the only place it *can* be surfaced: with
/// Apple Intelligence off, `Pipeline.localFormatter()` returns `nil`, the chain
/// is built with no local candidate, and so no fall-through is ever logged
/// either. The user just gets plainer text with no explanation anywhere.
@Suite("Doctor")
struct DoctorTests {
    @Test("the report includes on-device formatting")
    func reportIncludesFormattingCheck() {
        #expect(DoctorReport.run().contains { $0.name == "on-device formatting" })
    }

    /// A hard requirement, not a preference: `Run` gates startup on
    /// `DoctorReport.allOK`, so a `.fail` here would refuse to start the daemon
    /// on every Mac without Apple Intelligence — which is most of them. The app
    /// is fully functional on the rule-based floor.
    @Test("an unavailable model is a warning, never a failure")
    func unavailableIsOnlyAWarning() {
        let check = DoctorReport.checkOnDeviceFormatting()
        if case .fail = check.status {
            Issue.record("on-device formatting must never block startup")
        }
        #expect(DoctorReport.allOK([check]))
    }

    @Test("the check agrees with the formatter it is reporting on")
    func checkAgreesWithAvailability() {
        let check = DoctorReport.checkOnDeviceFormatting()
        guard #available(macOS 26.0, *) else {
            guard case .warn(let reason) = check.status else {
                Issue.record("below macOS 26 the model cannot exist")
                return
            }
            #expect(reason.contains("macOS 26"))
            return
        }
        switch check.status {
        case .ok:
            #expect(FoundationModelsFormatter.isAvailable)
            #expect(FoundationModelsFormatter.unavailableReason == nil)
        case .warn(let reason):
            // The load-bearing half on this machine, where Apple Intelligence
            // is switched off: the check must not claim availability, and it
            // must say why rather than only that.
            #expect(!FoundationModelsFormatter.isAvailable)
            #expect(!reason.isEmpty)
            #expect(FoundationModelsFormatter.unavailableReason == reason)
            #expect(check.remediation != nil)
        case .fail:
            Issue.record("covered above")
        }
    }
}
