import Foundation

public struct Command: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var stdin: Data?
    public var environment: [String: String]
    public var limit: TimeInterval?

    public init(
        _ executable: String, _ arguments: [String] = [], stdin: Data? = nil, environment: [String: String] = [:],
        limit: TimeInterval? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.environment = environment
        self.limit = limit
    }
}

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var output: String
    public var error: String

    public init(status: Int32 = 0, output: String = "", error: String = "") {
        self.status = status
        self.output = output
        self.error = error
    }

    public static let timedOut: Int32 = 124

    public var succeeded: Bool { status == 0 }
}

public typealias CommandRunner = @Sendable (Command) -> CommandResult

public enum PoolProcess {
    public static let run: CommandRunner = { command in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        if !command.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        }
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch { return CommandResult(status: 127, error: "\(error.localizedDescription)") }
        let timer = TimeLimit(process)
        if let limit = command.limit { timer.start(after: limit) }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let text = ReadBox()
        let errors = ReadBox()
        let group = DispatchGroup()
        for (pipe, box) in [(output, text), (error, errors)] {
            group.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    group.leave()
                } else {
                    box.append(chunk)
                }
            }
        }
        if let data = command.stdin { try? input.fileHandleForWriting.write(contentsOf: data) }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        // A child the command started in the background can keep the pipes open after it exits.
        if group.wait(timeout: .now() + 2) == .timedOut {
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
        }
        timer.cancel()
        if timer.expired { return CommandResult(status: CommandResult.timedOut, error: "timed out") }
        return CommandResult(
            status: process.terminationStatus, output: String(decoding: text.data, as: UTF8.self),
            error: String(decoding: errors.data, as: UTF8.self))
    }
}

private final class TimeLimit: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var item: DispatchWorkItem?
    private var fired = false

    init(_ process: Process) {
        self.process = process
    }

    var expired: Bool { lock.withLock { fired } }

    func start(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [self] in
            lock.withLock { fired = true }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        lock.withLock { item = work }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func cancel() {
        lock.withLock { item }?.cancel()
    }
}

private final class ReadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()

    var data: Data { lock.withLock { stored } }

    func append(_ chunk: Data) { lock.withLock { stored.append(chunk) } }
}

public enum Shell {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
