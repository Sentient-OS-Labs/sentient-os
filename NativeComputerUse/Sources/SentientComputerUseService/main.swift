@preconcurrency import Foundation
import SentientComputerUseCore

public enum ServiceLoop {
    private static let readChunkSize = 64 * 1024
    private static let maximumLineSize = 1 * 1024 * 1024

    public static func run(
        input: FileHandle,
        output: FileHandle,
        dispatcher: ServiceDispatcher
    ) async {
        defer { dispatcher.cleanup() }

        await withTaskCancellationHandler(operation: {
            await runLoop(input: input, output: output, dispatcher: dispatcher)
        }, onCancel: {
            try? input.close()
        })
    }

    private static func runLoop(
        input: FileHandle,
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

        if reachedEOF {
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

let dispatcher = ServiceDispatcher()
await ServiceLoop.run(input: .standardInput, output: .standardOutput, dispatcher: dispatcher)
