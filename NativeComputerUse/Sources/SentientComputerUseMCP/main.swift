@preconcurrency import Foundation
import Darwin
import SentientComputerUseCore

struct ChildShutdownTimeouts: Sendable, Equatable {
    let graceful: TimeInterval
    let terminate: TimeInterval
    let kill: TimeInterval

    static let `default` = ChildShutdownTimeouts(graceful: 1, terminate: 1, kill: 1)
}

protocol ServiceChildProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    var processIdentifier: Int32 { get }
    func start() throws
    func waitForExit(timeout: TimeInterval) -> Bool
    func terminate()
    func kill()
}

private final class FoundationServiceChildProcess: ServiceChildProcess, @unchecked Sendable {
    private let process: Process
    private let exitSignal = DispatchSemaphore(value: 0)

    init(executableURL: URL, arguments: [String], input: Pipe, output: Pipe) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        self.process = process
        process.terminationHandler = { [exitSignal] _ in exitSignal.signal() }
    }

    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    func start() throws {
        try process.run()
    }

    func waitForExit(timeout: TimeInterval) -> Bool {
        guard process.isRunning else { return true }
        let result = exitSignal.wait(timeout: .now() + timeout)
        return result == .success || !process.isRunning
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func kill() {
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
}

actor ServiceProcessTransport: ServiceTransport {
    private let process: any ServiceChildProcess
    private let requestInput: FileHandle
    private let responseOutput: FileHandle
    private let shutdownTimeouts: ChildShutdownTimeouts
    private var responseBuffer = Data()
    private var isShutDown = false

    init(
        executableURL: URL,
        arguments: [String] = [],
        shutdownTimeouts: ChildShutdownTimeouts = .default
    ) throws {
        signal(SIGPIPE, SIG_IGN)
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = FoundationServiceChildProcess(
            executableURL: executableURL,
            arguments: arguments,
            input: inputPipe,
            output: outputPipe
        )

        self.process = process
        requestInput = inputPipe.fileHandleForWriting
        responseOutput = outputPipe.fileHandleForReading
        self.shutdownTimeouts = shutdownTimeouts

        do {
            try process.start()
        } catch {
            try? requestInput.close()
            try? responseOutput.close()
            try? inputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            throw ServiceError(
                code: .internalError,
                message: "Unable to launch SentientComputerUseService"
            )
        }

        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
    }

    init(
        process: any ServiceChildProcess,
        requestInput: FileHandle,
        responseOutput: FileHandle,
        shutdownTimeouts: ChildShutdownTimeouts = .default
    ) throws {
        signal(SIGPIPE, SIG_IGN)
        self.process = process
        self.requestInput = requestInput
        self.responseOutput = responseOutput
        self.shutdownTimeouts = shutdownTimeouts
        do {
            try process.start()
        } catch {
            try? requestInput.close()
            try? responseOutput.close()
            throw ServiceError(code: .internalError, message: "Unable to launch SentientComputerUseService")
        }
    }

    var childProcessIdentifier: Int32 { process.processIdentifier }

    func call(operation: ServiceOperation, arguments: [String: JSONValue]) async throws -> JSONValue {
        guard !isShutDown, process.isRunning else { throw childExitedError }

        let id = UUID().uuidString
        var request = try JSONEncoder().encode(ServiceRequest(id: id, operation: operation, arguments: arguments))
        request.append(0x0A)
        do {
            try requestInput.write(contentsOf: request)
        } catch {
            throw childExitedError
        }

        let line = try readResponseLine()
        let response: ServiceResponse
        do {
            response = try JSONDecoder().decode(ServiceResponse.self, from: line)
        } catch {
            throw ServiceError(code: .internalError, message: "Invalid response from SentientComputerUseService")
        }
        guard response.id == id else {
            throw ServiceError(code: .internalError, message: "Mismatched response from SentientComputerUseService")
        }

        switch response {
        case .success(_, let result):
            return result
        case .failure(_, let error):
            throw error
        }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        try? requestInput.close()

        // EOF gives the service a bounded chance to clean up. Each escalation also has a hard
        // bound: adapter shutdown never performs an unbounded process wait.
        if process.waitForExit(timeout: shutdownTimeouts.graceful) {
            try? responseOutput.close()
            return
        }
        if process.isRunning {
            process.terminate()
        }
        if process.waitForExit(timeout: shutdownTimeouts.terminate) {
            try? responseOutput.close()
            return
        }
        if process.isRunning {
            process.kill()
        }
        _ = process.waitForExit(timeout: shutdownTimeouts.kill)
        try? responseOutput.close()
    }

    private func readResponseLine() throws -> Data {
        while true {
            if let newline = responseBuffer.firstIndex(of: 0x0A) {
                let line = Data(responseBuffer[..<newline])
                responseBuffer.removeSubrange(...newline)
                return line
            }

            let chunk: Data
            do {
                let read = responseOutput.availableData
                guard !read.isEmpty else {
                    throw childExitedError
                }
                chunk = read
            } catch let error as ServiceError {
                throw error
            } catch {
                throw childExitedError
            }
            responseBuffer.append(chunk)
        }
    }

    private var childExitedError: ServiceError {
        ServiceError(code: .internalError, message: "SentientComputerUseService exited")
    }
}

private final class TerminationSignals: @unchecked Sendable {
    private let sources: [DispatchSourceSignal]

    init(input: FileHandle) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        sources = [SIGINT, SIGTERM].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { try? input.close() }
            source.resume()
            return source
        }
    }
}

private func siblingServiceURL() -> URL {
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let adapter = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: currentDirectory)
        .standardizedFileURL
        .resolvingSymlinksInPath()
    return adapter.deletingLastPathComponent().appendingPathComponent("SentientComputerUseService")
}

do {
    signal(SIGPIPE, SIG_IGN)
    let transport = try ServiceProcessTransport(executableURL: siblingServiceURL())
    let terminationSignals = TerminationSignals(input: .standardInput)
    _ = terminationSignals
    await MCPStdio.run(
        input: .standardInput,
        output: .standardOutput,
        server: MCPServer(transport: transport)
    )
    withExtendedLifetime(terminationSignals) {}
    await transport.shutdown()
} catch {
    FileHandle.standardError.write(Data("SentientComputerUseMCP: unable to start service\n".utf8))
    exit(EXIT_FAILURE)
}
