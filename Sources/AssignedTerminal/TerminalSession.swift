@preconcurrency import Dispatch
@preconcurrency import Foundation

#if os(Linux)
import Glibc
import AssignedTerminalC
#elseif os(macOS)
import Darwin
import AssignedTerminalC
#endif

public struct TerminalSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

public enum TerminalSessionError: Error, Equatable, Sendable, CustomStringConvertible {
    case notATerminal
    case setup(String)
    case inputClosed
    case interrupted

    public var description: String {
        switch self {
        case .notATerminal: "interactive mode needs a terminal; use --json for scripts"
        case let .setup(message): "could not prepare terminal: \(message)"
        case .inputClosed: "terminal input closed"
        case .interrupted: "interrupted"
        }
    }
}

public final class TerminalSession: @unchecked Sendable {
    public static var isTerminal: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDERR_FILENO) == 1
    }

    private let inputFD: Int32
    private let output: FileHandle
    private var original: termios?
    private var restored = false
    private var decoder = KeyDecoder()
    private var pendingKeys: [TerminalKey] = []

    public init(inputFD: Int32 = STDIN_FILENO, output: FileHandle = .standardError) throws {
        self.inputFD = inputFD
        self.output = output
        var settings = termios()
        guard tcgetattr(inputFD, &settings) == 0 else {
            throw TerminalSessionError.notATerminal
        }
        original = settings
        guard assigned_signal_install() == 0 else {
            throw TerminalSessionError.setup("signal bridge")
        }
        var raw = settings
        cfmakeraw(&raw)
        guard tcsetattr(inputFD, TCSANOW, &raw) == 0 else {
            assigned_signal_close()
            throw TerminalSessionError.setup("raw mode")
        }
    }

    deinit { restore() }

    public func restore() {
        guard !restored else { return }
        if var original {
            _ = tcsetattr(inputFD, TCSANOW, &original)
        }
        assigned_signal_close()
        restored = true
    }

    public func write(_ text: String) {
        try? output.write(contentsOf: Data(text.utf8))
    }

    public func size() -> TerminalSize {
        var window = winsize()
        #if os(Linux)
        let ioctlRequest = UInt(TIOCGWINSZ)
        #else
        let ioctlRequest = TIOCGWINSZ
        #endif
        guard ioctl(outputFileDescriptor, ioctlRequest, &window) == 0 else {
            return TerminalSize(columns: 80, rows: 24)
        }
        let columns = Int(window.ws_col)
        let rows = Int(window.ws_row)
        return TerminalSize(columns: max(columns, 1), rows: max(rows, 1))
    }

    public func readKey() async throws -> TerminalKey {
        try Task.checkCancellation()
        if let key = dequeuePendingKey() { return key }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInteractive).async { [self] in
                    do {
                        continuation.resume(returning: try readKeyBlocking())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            _ = assigned_signal_wake()
        })
    }

    private var outputFileDescriptor: Int32 {
        #if os(Linux)
        return STDERR_FILENO
        #else
        return STDERR_FILENO
        #endif
    }

    private func readKeyBlocking() throws -> TerminalKey {
        if let key = dequeuePendingKey() { return key }
        while true {
            var descriptors = [
                pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: Int32(assigned_signal_read_fd()), events: Int16(POLLIN), revents: 0),
            ]
            let timeout: Int32 = decoder.hasPendingEscape ? 40 : -1
            let result = poll(&descriptors, nfds_t(descriptors.count), timeout)
            if result < 0 {
                if errno == EINTR { continue }
                throw TerminalSessionError.setup("poll")
            }
            if result == 0 {
                if let key = decoder.flushEscape() { return key }
                continue
            }
            if descriptors[1].revents & Int16(POLLIN) != 0 {
                var signal = UInt8(0)
                let count = read(descriptors[1].fd, &signal, 1)
                if count > 0 {
                    if signal == 0 { throw CancellationError() }
                    throw TerminalSessionError.interrupted
                }
                if count < 0, errno != EINTR, errno != EAGAIN {
                    throw TerminalSessionError.setup("signal read")
                }
                continue
            }
            if descriptors[0].revents & Int16(POLLIN) == 0 {
                if descriptors[0].revents & Int16(POLLHUP | POLLERR) != 0 {
                    throw TerminalSessionError.inputClosed
                }
                continue
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(inputFD, &buffer, buffer.count)
            if count == 0 { throw TerminalSessionError.inputClosed }
            if count < 0 {
                if errno == EINTR { continue }
                throw TerminalSessionError.setup("read")
            }
            pendingKeys.append(contentsOf: decoder.feed(Array(buffer.prefix(Int(count)))))
            if let key = dequeuePendingKey() { return key }
            if decoder.hasPendingEscape {
                continue
            }
        }
    }

    private func dequeuePendingKey() -> TerminalKey? {
        guard !pendingKeys.isEmpty else { return nil }
        return pendingKeys.removeFirst()
    }
}
