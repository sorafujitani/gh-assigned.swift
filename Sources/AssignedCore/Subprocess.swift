@preconcurrency import Dispatch
@preconcurrency import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var cancelled = false

    func attach(process: Process, input: FileHandle?) {
        lock.lock()
        self.process = process
        let shouldCancel = cancelled
        if !shouldCancel { self.input = input }
        lock.unlock()

        if shouldCancel {
            input?.closeFile()
            terminate(process)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        let input = self.input
        self.input = nil
        lock.unlock()

        input?.closeFile()
        if let process {
            terminate(process)
        }
    }

    private func terminate(_ process: Process) {
        let processIdentifier = process.processIdentifier
        guard processIdentifier > 0, process.isRunning else { return }

        _ = kill(processIdentifier, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(200)) {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.process === process,
                  process.processIdentifier == processIdentifier,
                  process.isRunning else { return }
            _ = kill(processIdentifier, SIGKILL)
        }
    }

    func closeInput() {
        lock.lock()
        let input = self.input
        self.input = nil
        lock.unlock()
        input?.closeFile()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public enum Subprocess {
    public static func run(executable: String, arguments: [String], stdin: Data? = nil) async throws -> CommandResult {
        let processBox = ProcessBox()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread {
                    do {
                        let process = Process()
                        let output = Pipe()
                        let error = Pipe()
                        let input = Pipe()
                        process.executableURL = URL(fileURLWithPath: executablePath(executable))
                        process.arguments = arguments
                        process.standardOutput = output
                        process.standardError = error
                        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
                        try process.run()
                        processBox.attach(
                            process: process,
                            input: stdin == nil ? nil : input.fileHandleForWriting
                        )

                        let group = DispatchGroup()
                        let stdout = DataBox()
                        let stderr = DataBox()
                        group.enter()
                        Thread.detachNewThread {
                            stdout.set(output.fileHandleForReading.readDataToEndOfFile())
                            group.leave()
                        }
                        group.enter()
                        Thread.detachNewThread {
                            stderr.set(error.fileHandleForReading.readDataToEndOfFile())
                            group.leave()
                        }

                        if let stdin, !processBox.isCancelled {
                            input.fileHandleForWriting.write(stdin)
                        }
                        processBox.closeInput()
                        process.waitUntilExit()
                        group.wait()
                        if processBox.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(returning: CommandResult(
                                status: process.terminationStatus,
                                stdout: stdout.value,
                                stderr: stderr.value
                            ))
                        }
                    } catch {
                        if processBox.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: SubprocessError.launch(String(describing: error)))
                        }
                    }
                }
            }
        }, onCancel: {
            processBox.cancel()
        })
    }

    private static func executablePath(_ executable: String) -> String {
        if executable.contains("/") { return executable }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(executable)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return executable
    }
}

public enum SubprocessError: Error, Equatable, Sendable, CustomStringConvertible {
    case launch(String)

    public var description: String {
        switch self { case let .launch(message): "could not launch process: \(message)" }
    }
}
