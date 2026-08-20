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
/// Raw addresses come first and always arrive; symbols follow when they can be
/// read. Symbols come back mangled, because demangling allocates and this runs
/// in a signal handler — `swift demangle` reads them, and `atos` resolves the
/// addresses if the symbol pass produced nothing:
///
/// ```text
/// ara crashed (signal 11) — raw frames first, then symbols if they can be read.
/// 0x0000000104a1b2c4
/// ...
/// 0   ara   0x0000000104a1b2c4 $s7AraCore12AudioCaptureC4stopSaySfGyF + 120
/// ...
/// ```
///
/// A LaunchAgent install captures stderr to a file, so this lands somewhere
/// durable without the user doing anything.
///
/// ## What is safe to do here, and what is not
///
/// Almost nothing is legal in a signal handler, and an earlier version of this
/// file was wrong about where the line falls. It claimed `backtrace_symbols_fd`
/// was on the safe list because it does not allocate. Not allocating is not the
/// same as being async-signal-safe: Darwin's implementation calls `dladdr` for
/// every frame, which takes the dynamic loader's lock. It also built its output
/// out of Swift `Array`s, which allocate.
///
/// Both are the same class of mistake, and the reason it matters here is
/// specific. This handler exists for a **use-after-free** — the bug it caught
/// was `objc_msgSend` on a freed `AVAudioEngine`. A process that faults on
/// corrupted heap is very often holding the malloc lock at that moment, and a
/// process that faults during a lazy bind is holding dyld's. Allocating or
/// symbolizing there does not crash; it *hangs*, and a hung daemon reports
/// nothing at all and does not even die. The handler was most likely to fail in
/// precisely the case it was written for.
///
/// So the order below is the design, not a style:
///
/// 1. **The guaranteed part first.** The header and the raw frame addresses go
///    out through `write` alone, from stack memory, with the digits rendered by
///    hand. No allocation, no locks, no library calls beyond `write` and
///    `backtrace` — which walks frame pointers and touches neither allocator
///    nor loader. If everything after this deadlocks, the addresses are already
///    on stderr, and `atos -o <binary> -l <load address>` turns them into a
///    stack.
/// 2. **A deadlock backstop.** `alarm` is async-signal-safe and `SIGALRM`'s
///    default disposition terminates. If symbolizing wedges on a lock, the
///    process dies a few seconds later instead of hanging forever holding the
///    hotkey tap.
/// 3. **The convenient part last, as best effort.** `backtrace_symbols_fd`
///    usually works and its output is far easier to read, so it is still worth
///    attempting — but only once nothing depends on it returning.
///
/// The handler then restores the default disposition and re-raises, so the
/// process still dies of the same signal with the same status. This changes
/// what a crash *reports*, never what it *does*.
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
    // Stack memory, so that capturing the stack does not need the heap the
    // process may have just corrupted. 128 frames is far past anything worth
    // reading and costs one kilobyte of stack.
    withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 128) { frames in
        let depth = backtrace(frames.baseAddress!, Int32(frames.count))

        writeStatic("\nara crashed (signal ")
        writeSignalNumber(signalNumber)
        writeStatic(") — raw frames first, then symbols if they can be read.\n")
        writeStatic("Demangle symbols with `swift demangle`; resolve raw frames with `atos`.\n")

        // The part that always survives: the addresses themselves.
        for index in 0 ..< Int(depth) {
            writeHexAddress(UInt(bitPattern: frames[index]))
            writeStatic("\n")
        }

        // `backtrace_symbols_fd` calls `dladdr` per frame and can block on the
        // dynamic loader's lock. Bound the damage before asking for it: if it
        // never returns, SIGALRM ends the process instead of wedging it.
        alarm(3)
        backtrace_symbols_fd(frames.baseAddress!, depth, 2)
        alarm(0)
    }

    // Die of the signal that was actually raised, with the status the caller
    // would have seen. Reporting a crash must not change its outcome.
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

/// Writes a compile-time string with no allocation: `StaticString` already
/// holds a pointer to its own UTF-8 bytes in the binary, so there is nothing to
/// build.
private func writeStatic(_ text: StaticString) {
    _ = write(2, text.utf8Start, text.utf8CodeUnitCount)
}

/// One or two digits, rendered by hand. Signal numbers are small and this is
/// not the place to call a formatter.
private func writeSignalNumber(_ number: Int32) {
    var digits = (UInt8(0), UInt8(0))
    withUnsafeMutableBytes(of: &digits) { buffer in
        var count = 0
        if number >= 10 {
            buffer[count] = UInt8(48 + (number / 10) % 10)
            count += 1
        }
        buffer[count] = UInt8(48 + number % 10)
        count += 1
        _ = write(2, buffer.baseAddress, count)
    }
}

/// `0x` and sixteen hex digits, into a fixed stack buffer.
///
/// This is the whole point of the first pass: an address is useless to read but
/// it is *always* obtainable, and `atos` turns a list of them back into the
/// same stack `backtrace_symbols_fd` would have printed.
private func writeHexAddress(_ value: UInt) {
    var buffer = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                  UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                  UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
    withUnsafeMutableBytes(of: &buffer) { bytes in
        bytes[0] = UInt8(ascii: "0")
        bytes[1] = UInt8(ascii: "x")
        for position in 0 ..< 16 {
            let nibble = UInt8((value >> UInt((15 - position) * 4)) & 0xF)
            bytes[2 + position] = nibble < 10
                ? UInt8(ascii: "0") + nibble
                : UInt8(ascii: "a") + (nibble - 10)
        }
        _ = write(2, bytes.baseAddress, 18)
    }
}
