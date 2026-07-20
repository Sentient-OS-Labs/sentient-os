import Foundation
import SentientComputerUseCore
import SentientComputerUseService
import XCTest

final class ServiceLoopTests: XCTestCase {
    func testContinuesAfterMalformedLine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("input.ndjson")
        let outputURL = directory.appendingPathComponent("output.ndjson")
        let input = Data("""
        {\"id\":\"first\",\"operation\":\"list_apps\",\"arguments\":{}}
        not-json
        {\"id\":\"second\",\"operation\":\"list_apps\",\"arguments\":{}}
        """.utf8)
        try input.write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        await ServiceLoop.run(input: inputHandle, output: outputHandle, dispatcher: ServiceDispatcher())
        try inputHandle.close()
        try outputHandle.close()

        let responses = try String(contentsOf: outputURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(ServiceResponse.self, from: Data($0.utf8)) }

        XCTAssertEqual(responses.count, 3)
        XCTAssertEqual(responses[0].id, "first")
        XCTAssertEqual(responses[1], .failure(id: "", ServiceError(code: .invalidRequest, message: "Invalid request")))
        XCTAssertEqual(responses[2].id, "second")
    }

    func testDiscardsPartialLineWhenInputClosesWithAnError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("output.ndjson")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("not-json".utf8))

        let task = Task {
            await ServiceLoop.run(
                input: pipe.fileHandleForReading,
                output: output,
                dispatcher: ServiceDispatcher()
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        try pipe.fileHandleForReading.close()
        await task.value
        try output.close()

        XCTAssertEqual(try Data(contentsOf: outputURL), Data())
    }
}
