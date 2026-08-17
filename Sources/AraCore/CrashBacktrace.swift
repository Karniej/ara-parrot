import Darwin
import Foundation

/// Prints a backtrace to stderr when the daemon dies of a memory fault, then
/// lets it die exactly as it would have.
///
/// ## Why this exists
///
/// A user reported a segfault. There was nothing to look at: this machine
/// writes no crash reports at all — `~/Library/Logs/DiagnosticReports` does not
/// exist, and a deliberately faulting test binary produced no `.ips` either —
/// and core dumps need a root-writable `/cores`. The only way to see the stack
/// was to attach `lldb` to a running daemon and wait for it to happen again,
/// which worked, and which nobody should have to do.
///
/// What it caught was worth catching: `objc_msgSend` on a freed
/// `AVAudioEngine`, from a block AVFAudio had dispatched to its own queue. That
/// is not a diagnosis anybody reaches from "it quit unexpectedly". So the
/// daemon now carries the thing that made it visible.
///
/// ## What the output is good for
///
/// Symbols come back mangled, because demangling allocates and this runs in a
/// signal handler. `swift demangle` reads them:
///
/// ```
/// ara crashed (signal 11) — backtrace:
/// 0   ara   0x0000000104a1b2c4 $s7AraCore12AudioCaptureC4stopSaySfGyF + 120
/// ...
/// ```
///
/// A LaunchAgent install captures stderr to a file, so this lands somewhere
/// durable without the user doing anything.
///
/// ## What is safe to do here, and what is not
///
/// Almost nothing is legal in a signal handler. `backtrace` and
/// `backtrace_symbols_fd` are on the short list that is — the `_fd` spelling
/// exists precisely because the array-returning `backtrace_symbols` allocates,
/// and allocating on a thread that faulted while holding the malloc lock
/// deadlocks a process that was only trying to explain itself. `write` is
/// likewise safe. Nothing here touches Foundation, Swift runtime metadata, or
/// any lock.
///
/// The handler restores the default disposition and re-raises, so the process
/// still dies of the same signal with the same status. This changes what a
/// crash *reports*, never what it *does*.
public enum CrashBacktrace {
    /// The signals worth a stack. All of them mean memory went wrong, and none
    /// of them is recoverable.
    ///
    /// `SIGABRT` is deliberately absent: Swift's own fatal errors (a nil
    /// unwrap, an array bound, a precondition) go through it, and those already
    /// print a file, a line and a reason that beats a mangled stack. Adding it
    /// would bury a good message under a worse one.
    private static let fatalSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGFPE]

    /// Installs the handler. Call once, as early as possible — a crash before
    /// this line is still silent.
    ///
    /// Idempotent, and cheap enough that it does not matter: re-installing the
    /// same handler for the same signal is what the second call would do.
    public static func install() {
        for signalNumber in fatalSignals {
            signal(signalNumber, handleFatalSignal)
        }
    }
}

/// A file-scope function rather than a closure or a static method: `signal`
/// takes a C function pointer, and only something with no context can be one.
private func handleFatalSignal(_ signalNumber: Int32) {
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
    let depth = backtrace(&frames, Int32(frames.count))

    // Built with `withVaList`-free string interpolation avoided entirely: the
    // number is rendered by hand so nothing allocates. Signal numbers are one
    // or two digits, and this is not the place to be clever.
    var header = Array("\nara crashed (signal ".utf8)
    if signalNumber >= 10 {
        header.append(UInt8(48 + (signalNumber / 10)))
    }
    header.append(UInt8(48 + (signalNumber % 10)))
    header.append(contentsOf: Array(") — backtrace follows. Demangle it with `swift demangle`.\n".utf8))
    header.withUnsafeBufferPointer { buffer in
        _ = write(2, buffer.baseAddress, buffer.count)
    }

    backtrace_symbols_fd(&frames, depth, 2)

    // Die of the signal that was actually raised, with the status the caller
    // would have seen. Reporting a crash must not change its outcome.
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}
