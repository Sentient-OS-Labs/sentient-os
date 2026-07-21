@preconcurrency import Foundation
import Darwin
import SentientComputerUseCore

protocol ServiceInputReading: Sendable {
    func read(upToCount count: Int) throws -> Data?
    func close()
}

private final class FileHandleInput: ServiceInputReading, @unchecked Sendable {
    private let handle: FileHandle
    private let descriptor: Int32

    init(handle: FileHandle) {
        self.handle = handle
        descriptor = handle.fileDescriptor
    }

    func read(upToCount count: Int) throws -> Data? {
        let data = handle.availableData
        if data.isEmpty, fcntl(descriptor, F_GETFD) == -1, errno == EBADF {
            throw CocoaError(.fileReadUnknown)
        }
        return data
    }

    func close() {
        try? handle.close()
    }
}

public enum ServiceLoop {
    private static let readChunkSize = 64 * 1024
    private static let maximumLineSize = 1 * 1024 * 1024
    private static let maximumResponseLineSize = 1 * 1024 * 1024

    public static func run(
        input: FileHandle,
        output: FileHandle,
        dispatcher: ServiceDispatcher
    ) async {
        await run(input: FileHandleInput(handle: input), output: output, dispatcher: dispatcher)
    }

    static func run(
        input: any ServiceInputReading,
        output: FileHandle,
        dispatcher: ServiceDispatcher
    ) async {
        defer { dispatcher.cleanup() }

        await withTaskCancellationHandler(operation: {
            await runLoop(input: input, output: output, dispatcher: dispatcher)
        }, onCancel: {
            input.close()
        })
    }

    private static func runLoop(
        input: any ServiceInputReading,
        output: FileHandle,
        dispatcher: ServiceDispatcher
    ) async {
        let codec = NDJSONCodec()
        var line = Data()
        var discardingOversizedLine = false
        var reachedEOF = false

        while !Task.isCancelled {
            let chunk: Data
            do {
                guard let read = try input.read(upToCount: readChunkSize), !read.isEmpty else {
                    reachedEOF = true
                    break
                }
                chunk = read
            } catch {
                break
            }

            for byte in chunk {
                guard !Task.isCancelled else { return }
                if byte == 0x0A {
                    if discardingOversizedLine {
                        guard await writeInvalidRequest(output: output, codec: codec) else { return }
                        discardingOversizedLine = false
                    } else {
                        guard await process(line: line, output: output, dispatcher: dispatcher, codec: codec) else { return }
                        line.removeAll(keepingCapacity: true)
                    }
                    continue
                }

                guard !discardingOversizedLine else { continue }
                guard line.count < maximumLineSize else {
                    line.removeAll(keepingCapacity: false)
                    discardingOversizedLine = true
                    continue
                }
                line.append(byte)
            }
        }

        if reachedEOF, !Task.isCancelled {
            if discardingOversizedLine {
                _ = await writeInvalidRequest(output: output, codec: codec)
            } else if !line.isEmpty {
                _ = await process(line: line, output: output, dispatcher: dispatcher, codec: codec)
            }
        }
    }

    private static func process(
        line: Data,
        output: FileHandle,
        dispatcher: ServiceDispatcher,
        codec: NDJSONCodec
    ) async -> Bool {
        let response: ServiceResponse
        if let request = await codec.decodeRequest(line) {
            response = await dispatcher.handle(request)
        } else {
            response = invalidRequestResponse
        }
        return await write(response, output: output, codec: codec)
    }

    private static func writeInvalidRequest(output: FileHandle, codec: NDJSONCodec) async -> Bool {
        await write(invalidRequestResponse, output: output, codec: codec)
    }

    private static func write(_ response: ServiceResponse, output: FileHandle, codec: NDJSONCodec) async -> Bool {
        var data = await codec.encodeResponse(response)
        if data.count + 1 > maximumResponseLineSize {
            data = await codec.encodeResponse(.failure(
                id: response.id,
                ServiceError(code: .internalError, message: "Response exceeds maximum size")
            ))
        }
        data.append(0x0A)
        do {
            try output.write(contentsOf: data)
        } catch {
            return false
        }
        do {
            try output.synchronize()
        } catch {
            // Synchronization is unsupported by pipes even after a successful write.
        }
        return true
    }

    private static var invalidRequestResponse: ServiceResponse {
        .failure(id: "", ServiceError(code: .invalidRequest, message: "Invalid request"))
    }
}

private actor NDJSONCodec {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func decodeRequest(_ data: Data) -> ServiceRequest? {
        try? decoder.decode(ServiceRequest.self, from: data)
    }

    func encodeResponse(_ response: ServiceResponse) -> Data {
        try! encoder.encode(response)
    }
}

private final class ServiceTerminationSignals: @unchecked Sendable {
    private let sources: [DispatchSourceSignal]

    init(input: FileHandle) {
        signal(SIGPIPE, SIG_IGN)
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

signal(SIGPIPE, SIG_IGN)
let dispatcher = ServiceDispatcher()
let arguments = CommandLine.arguments
if let requestIndex = arguments.firstIndex(of: "--request-file"),
   let responseIndex = arguments.firstIndex(of: "--response-file"),
   arguments.indices.contains(requestIndex + 1),
   arguments.indices.contains(responseIndex + 1) {
    let requestURL = URL(fileURLWithPath: arguments[requestIndex + 1]).standardizedFileURL
    let responseURL = URL(fileURLWithPath: arguments[responseIndex + 1]).standardizedFileURL
    let ipcRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("SentientComputerUseIPC", isDirectory: true)
        .standardizedFileURL
    let requestIsLocal = requestURL.path.hasPrefix(ipcRoot.path + "/")
    let responseIsLocal = responseURL.path.hasPrefix(ipcRoot.path + "/")

    guard requestIsLocal, responseIsLocal,
          let requestData = try? Data(contentsOf: requestURL),
          let request = try? JSONDecoder().decode(ServiceRequest.self, from: requestData) else {
        exit(EXIT_FAILURE)
    }
    let response = await dispatcher.handle(request)
    guard let responseData = try? JSONEncoder().encode(response) else { exit(EXIT_FAILURE) }
    do {
        try responseData.write(to: responseURL, options: .atomic)
        dispatcher.cleanup()
    } catch {
        exit(EXIT_FAILURE)
    }
} else {
    let terminationSignals = ServiceTerminationSignals(input: .standardInput)
    await ServiceLoop.run(input: .standardInput, output: .standardOutput, dispatcher: dispatcher)
    withExtendedLifetime(terminationSignals) {}
}
