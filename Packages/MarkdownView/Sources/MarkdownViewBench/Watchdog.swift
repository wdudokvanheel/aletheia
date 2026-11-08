import Darwin
import Foundation
import Synchronization

/// Ends the result file when the process cannot: a crash signal, or the watchdog finding the main
/// thread stuck. Before each document the writer arms the bytes that replace its `running` line:
/// the document as `crashed` or `hung`, then `],"aggregate":null,"interrupted":{...}}`.
enum Interruption {
    private nonisolated(unsafe) static var fd: Int32 = -1
    private nonisolated(unsafe) static var offset: off_t = 0
    private nonisolated(unsafe) static var crashed = UnsafeMutableBufferPointer<UInt8>(start: nil, count: 0)
    /// Where the two digits of `signal 00` are in `crashed`.
    private nonisolated(unsafe) static var signalDigits = 0
    private nonisolated(unsafe) static var hung = UnsafeMutableBufferPointer<UInt8>(start: nil, count: 0)
    private nonisolated(unsafe) static var message = UnsafeMutableBufferPointer<UInt8>(start: nil, count: 0)
    static let signalPlaceholder = "signal 00"

    private static func copy(_ text: String) -> UnsafeMutableBufferPointer<UInt8> {
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: text.utf8.count)
        _ = buffer.initialize(from: text.utf8)
        return buffer
    }

    /// Called on the main thread between documents, when no document code runs.
    static func arm(fd: Int32, offset: UInt64, crashed crashTail: String, hung hangTail: String, message text: String) {
        disarm()
        crashed = copy(crashTail)
        signalDigits = crashTail.range(of: signalPlaceholder).map {
            crashTail.utf8.distance(from: crashTail.startIndex, to: $0.upperBound) - 2 } ?? -1
        hung = copy(hangTail)
        message = copy(text)
        self.offset = off_t(offset)
        self.fd = fd
    }

    static func disarm() {
        fd = -1
        for buffer in [crashed, hung, message] { buffer.deallocate() }
        crashed = .init(start: nil, count: 0)
        hung = .init(start: nil, count: 0)
        message = .init(start: nil, count: 0)
    }

    /// Async-signal-safe: replaces the running line and closes the file, once.
    private static func write(_ tail: UnsafeMutableBufferPointer<UInt8>) {
        guard fd >= 0, let base = tail.baseAddress else { return }
        let file = fd
        fd = -1
        _ = ftruncate(file, offset)
        _ = lseek(file, offset, SEEK_SET)
        _ = Darwin.write(file, base, tail.count)
        if let text = message.baseAddress { _ = Darwin.write(2, text, message.count) }
    }

    /// Fatal signals, including Swift traps (SIGTRAP), handled on an alternate stack on the main thread.
    static func installHandlers() {
        let size = 1 << 16
        var stack = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16), ss_size: size, ss_flags: 0)
        sigaltstack(&stack, nil)
        let handler: @convention(c) (Int32) -> Void = { signal in
            if Interruption.fd >= 0, Interruption.signalDigits >= 0, Interruption.signalDigits + 1 < Interruption.crashed.count {
                Interruption.crashed[Interruption.signalDigits] = UInt8(48 + signal / 10 % 10)
                Interruption.crashed[Interruption.signalDigits + 1] = UInt8(48 + signal % 10)
            }
            Interruption.write(Interruption.crashed)
            // SA_RESETHAND does not apply to SIGILL and SIGTRAP, so restore the default action
            // explicitly; it runs when the faulting instruction repeats or the raise is delivered.
            Darwin.signal(signal, SIG_DFL)
            raise(signal)
        }
        for signal in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            var action = sigaction()
            action.__sigaction_u = __sigaction_u(__sa_handler: handler)
            action.sa_flags = SA_ONSTACK | SA_RESETHAND
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
    }

    /// From the watchdog thread, while the main thread is stuck.
    static func hang(seconds: Double) -> Never {
        fputs(String(format: "\nerror: the main thread has not returned to its run loop for %.0f s\n", seconds), stderr)
        write(hung)
        _exit(3)
    }
}

/// Watches the main run loop: the longest busy span (between run loop activities, not counting
/// waits) per document, and the end of the run when one span exceeds `hangSeconds`.
final class Watchdog: Sendable {
    private struct State {
        var last = now()
        var waiting = false
        var longest: UInt64 = 0
    }

    private let state = Mutex(State())
    let hangSeconds: Double

    init(hangSeconds: Double) {
        self.hangSeconds = hangSeconds
    }

    @MainActor
    func start() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) {
            [self] _, activity in
            let time = now()
            state.withLock { state in
                if !state.waiting { state.longest = max(state.longest, time &- state.last) }
                state.last = time
                state.waiting = activity == .beforeWaiting
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let limit = UInt64(hangSeconds * 1e9)
        Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                let busy = state.withLock { $0.waiting ? 0 : now() &- $0.last }
                if busy > limit { Interruption.hang(seconds: Double(busy) / 1e9) }
            }
        }.start()
    }

    /// The longest busy span in milliseconds since the previous call.
    func takeLongest() -> Double {
        state.withLock { state in
            let longest = max(state.longest, state.waiting ? 0 : now() &- state.last)
            state.longest = 0
            return Double(longest) / 1e6
        }
    }
}
