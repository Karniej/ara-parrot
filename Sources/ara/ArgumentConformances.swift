import ArgumentParser
import AraCore

// The CLI's view of library types. These conformances lived inside AraCore,
// which made the *library* depend on ArgumentParser — the single blocker to
// compiling the engine for iOS, and a design bug regardless: how a value is
// parsed from argv is the executable's business, not the type's.
extension Hotkey: ExpressibleByArgument {}
extension InjectionSetting: ExpressibleByArgument {}
