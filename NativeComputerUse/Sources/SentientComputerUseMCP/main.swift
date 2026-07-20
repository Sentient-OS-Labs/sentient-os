@preconcurrency import Foundation
import Darwin
import SentientComputerUseCore

actor ServiceProcessTransport: ServiceTransport {
    private let process: Process
    private let requestInput: FileHandle
    private let responseOutput: FileHandle
    private var responseBuffer = Data()
    private var isShutDown = false

    init(executableURL: URL) throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()

        process.executableURL = executableURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            throw ServiceError(
                code: .internalError,
                message: "Unable to launch SentientComputerUseService"
            )
        }

        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        self.process = process
        requestInput = inputPipe.fileHandleForWriting
        responseOutput = outputPipe.fileHandleForReading
    }

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

        // EOF lets the service leave its loop and run capture cleanup. Bound the graceful wait,
        // then terminate so adapter shutdown can never leave an orphan process.
        let gracefulDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < gracefulDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
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
