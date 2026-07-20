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
                if byte == 0x0A {
                    if discardingOversizedLine {
                        await writeInvalidRequest(output: output, codec: codec)
                        discardingOversizedLine = false
                    } else {
                        await process(line: line, output: output, dispatcher: dispatcher, codec: codec)
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
                await writeInvalidRequest(output: output, codec: codec)
            } else if !line.isEmpty {
                await process(line: line, output: output, dispatcher: dispatcher, codec: codec)
            }
        }
    }

    private static func process(
        line: Data,
        output: FileHandle,
        dispatcher: ServiceDispatcher,
        codec: NDJSONCodec
    ) async {
        let response: ServiceResponse
        if let request = await codec.decodeRequest(line) {
            response = await dispatcher.handle(request)
        } else {
            response = invalidRequestResponse
        }
        await write(response, output: output, codec: codec)
    }

    private static func writeInvalidRequest(output: FileHandle, codec: NDJSONCodec) async {
        await write(invalidRequestResponse, output: output, codec: codec)
    }

    private static func write(_ response: ServiceResponse, output: FileHandle, codec: NDJSONCodec) async {
        var data = await codec.encodeResponse(response)
        data.append(0x0A)
        do {
            try output.write(contentsOf: data)
            try output.synchronize()
        } catch {
            // The caller owns the output handle. A write failure ends this response only.
        }
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
