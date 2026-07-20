import Darwin
import Foundation
import XCTest
@testable import SentientComputerUseCore
@testable import SentientComputerUseMCP

final class ServiceProcessTransportTests: XCTestCase {
    func testShutdownReturnsAfterGracefulChildExitWithoutSignals() async throws {
        let process = FakeServiceChildProcess(waitResults: [true])
        let fixtures = try TransportFixtures(process: process)

        await fixtures.transport.shutdown()

        XCTAssertEqual(process.startCount, 1)
        XCTAssertEqual(process.waitTimeouts, [0.01])
        XCTAssertEqual(process.terminateCount, 0)
        XCTAssertEqual(process.killCount, 0)
    }

    func testShutdownEscalatesFromEOFToSIGTERMToSIGKILLWithBoundedWaits() async throws {
        let process = FakeServiceChildProcess(waitResults: [false, false, true])
        let fixtures = try TransportFixtures(process: process)

        await fixtures.transport.shutdown()

        XCTAssertEqual(process.waitTimeouts, [0.01, 0.02, 0.03])
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 1)
    }

    func testSIGTERMResistantRealChildIsKilledAndReapedWithoutOrphan() async throws {
        let transport = try ServiceProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            shutdownTimeouts: .init(graceful: 0.03, terminate: 0.03, kill: 0.2)
        )
        let pid = await transport.childProcessIdentifier
        try await Task.sleep(for: .milliseconds(30))

        await transport.shutdown()

        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testChildExitFailsCallWithInternalError() async throws {
        let transport = try ServiceProcessTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            shutdownTimeouts: .fastTests
        )
        try await Task.sleep(for: .milliseconds(20))

        await assertInternalError(from: transport)
        await transport.shutdown()
    }

    func testMalformedChildResponseFailsCallWithInternalError() async throws {
        let transport = try ServiceProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "read line; printf 'not-json\\n'"],
            shutdownTimeouts: .fastTests
        )

        await assertInternalError(from: transport)
        await transport.shutdown()
    }

    func testMismatchedChildResponseFailsCallWithInternalError() async throws {
        let transport = try ServiceProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "read line; printf '%s\\n' '{\"id\":\"wrong\",\"result\":null}'"],
            shutdownTimeouts: .fastTests
        )

        await assertInternalError(from: transport)
        await transport.shutdown()
    }

    func testClosedRequestPipeFailsWriteWithInternalError() async throws {
        let process = FakeServiceChildProcess(waitResults: [true])
        let fixtures = try TransportFixtures(process: process)
        try fixtures.requestInput.close()

        await assertInternalError(from: fixtures.transport)
        await fixtures.transport.shutdown()
    }

    private func assertInternalError(
        from transport: ServiceProcessTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await transport.call(operation: .listApps, arguments: [:])
            XCTFail("Expected internal_error", file: file, line: line)
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, .internalError, file: file, line: line)
        } catch {
            XCTFail("Expected ServiceError, got \(error)", file: file, line: line)
        }
    }
}

private extension ChildShutdownTimeouts {
    static let fastTests = ChildShutdownTimeouts(graceful: 0.01, terminate: 0.01, kill: 0.1)
}

private final class TransportFixtures {
    let transport: ServiceProcessTransport
    let requestInput: FileHandle
    private let responseOutput: FileHandle
    private let requestPipe: Pipe
    private let responsePipe: Pipe

    init(process: FakeServiceChildProcess) throws {
        requestPipe = Pipe()
        responsePipe = Pipe()
        requestInput = requestPipe.fileHandleForWriting
        responseOutput = responsePipe.fileHandleForReading
        transport = try ServiceProcessTransport(
            process: process,
            requestInput: requestInput,
            responseOutput: responseOutput,
            shutdownTimeouts: .init(graceful: 0.01, terminate: 0.02, kill: 0.03)
        )
    }
}

private final class FakeServiceChildProcess: ServiceChildProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingWaitResults: [Bool]
    private var running = true
    private(set) var startCount = 0
    private(set) var waitTimeouts: [TimeInterval] = []
    private(set) var terminateCount = 0
    private(set) var killCount = 0

    init(waitResults: [Bool]) {
        remainingWaitResults = waitResults
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    var processIdentifier: Int32 { 12345 }

    func start() throws {
        lock.withLock { startCount += 1 }
    }

    func waitForExit(timeout: TimeInterval) -> Bool {
        lock.withLock {
            waitTimeouts.append(timeout)
            let result = remainingWaitResults.isEmpty ? false : remainingWaitResults.removeFirst()
            if result { running = false }
            return result
        }
    }

    func terminate() {
        lock.withLock { terminateCount += 1 }
    }

    func kill() {
        lock.withLock { killCount += 1 }
    }
}
