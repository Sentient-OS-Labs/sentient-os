import XCTest
@testable import SentientComputerUseCore
@testable import SentientComputerUseMCP

final class MCPServerTests: XCTestCase {
    func testInitializeNegotiatesProtocolAndToolCapability() async throws {
        let server = MCPServer(transport: RecordingTransport())

        let response = await server.handle(.object([
            "jsonrpc": .string("2.0"),
            "id": .int(1),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .string("2025-03-26"),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("tests"), "version": .string("1")])
            ])
        ]))

        XCTAssertEqual(response, .object([
            "jsonrpc": .string("2.0"),
            "id": .int(1),
            "result": .object([
                "protocolVersion": .string("2025-03-26"),
                "capabilities": .object([
                    "tools": .object(["listChanged": .bool(false)])
                ]),
                "serverInfo": .object([
                    "name": .string("sentient-computer-use"),
                    "version": .string("1.0.0")
                ])
            ])
        ]))
    }

    func testListsExactlyTheSixApprovedSkyCompatibleTools() async throws {
        let server = MCPServer(transport: RecordingTransport())

        let response = await server.handle(request(id: .string("tools"), method: "tools/list", params: .object([:])))

        XCTAssertEqual(response, .object([
            "jsonrpc": .string("2.0"),
            "id": .string("tools"),
            "result": .object(["tools": .array(Self.expectedTools)])
        ]))
    }

    func testToolCallForwardsOperationAndArgumentsWithoutRewriting() async throws {
        let transport = RecordingTransport(result: .object(["ok": .bool(true)]))
        let server = MCPServer(transport: transport)
        let arguments: [String: JSONValue] = [
            "app": .string("Notes"),
            "element_index": .int(7),
            "mouse_button": .string("left"),
            "click_count": .int(2)
        ]

        let response = await server.handle(request(
            id: .int(8),
            method: "tools/call",
            params: .object([
                "name": .string("click"),
                "arguments": .object(arguments)
            ])
        ))

        let calls = await transport.calls
        XCTAssertEqual(calls, [.init(operation: .click, arguments: arguments)])
        guard case let .object(envelope)? = response,
              case let .object(result)? = envelope["result"] else {
            return XCTFail("Expected an MCP tool result")
        }
        XCTAssertEqual(envelope["id"], .int(8))
        XCTAssertEqual(result["isError"], .bool(false))
        XCTAssertEqual(result["structuredContent"], .object(["ok": .bool(true)]))
        XCTAssertEqual(try decodedTextContent(result), .object(["ok": .bool(true)]))
    }

    func testToolCallPreservesStructuredServiceError() async throws {
        let serviceError = ServiceError(code: .permissionDeniedAccessibility, message: "Accessibility permission is required")
        let server = MCPServer(transport: RecordingTransport(error: serviceError))

        let response = await server.handle(request(
            id: .int(9),
            method: "tools/call",
            params: .object([
                "name": .string("get_app_state"),
                "arguments": .object(["app": .string("Notes")])
            ])
        ))

        guard case let .object(envelope)? = response,
              case let .object(result)? = envelope["result"] else {
            return XCTFail("Expected an MCP tool error result")
        }
        let expectedError: JSONValue = .object([
            "code": .string("permission_denied_accessibility"),
            "message": .string("Accessibility permission is required")
        ])
        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertEqual(result["structuredContent"], .object(["error": expectedError]))
        XCTAssertEqual(try decodedTextContent(result), .object(["error": expectedError]))
    }

    func testUnknownMethodReturnsMethodNotFound() async throws {
        let server = MCPServer(transport: RecordingTransport())

        let response = await server.handle(request(id: .int(10), method: "resources/list", params: .object([:])))

        XCTAssertEqual(response, jsonRPCError(id: .int(10), code: -32601, message: "Method not found"))
    }

    func testMalformedToolCallReturnsInvalidParams() async throws {
        let server = MCPServer(transport: RecordingTransport())

        let response = await server.handle(request(
            id: .int(11),
            method: "tools/call",
            params: .object([
                "name": .string("click"),
                "arguments": .array([])
            ])
        ))

        XCTAssertEqual(response, jsonRPCError(id: .int(11), code: -32602, message: "Invalid params"))
    }

    func testNotificationsProduceNoResponse() async throws {
        let server = MCPServer(transport: RecordingTransport())
        let initialized = await server.handle(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized")
        ]))
        let unknown = await server.handle(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/unknown"),
            "params": .object([:])
        ]))

        XCTAssertNil(initialized)
        XCTAssertNil(unknown)
    }

    private func request(id: JSONValue, method: String, params: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "method": .string(method),
            "params": params
        ])
    }

    private func jsonRPCError(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .int(code),
                "message": .string(message)
            ])
        ])
    }

    private func decodedTextContent(_ result: [String: JSONValue]) throws -> JSONValue {
        guard case let .array(content)? = result["content"],
              content.count == 1,
              case let .object(item) = content[0],
              item["type"] == .string("text"),
              case let .string(text)? = item["text"] else {
            throw TestFailure.invalidContent
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private static let expectedTools: [JSONValue] = [
        tool(
            name: "list_apps",
            description: "List the apps on this computer. Returns the set of apps that are currently running, as well as any that have been used in the last 14 days, including details on usage frequency",
            properties: [:],
            required: []
        ),
        tool(
            name: "get_app_state",
            description: "Start an app use session if needed, then get the state of the app's key window and return a screenshot and accessibility tree. This must be called once per assistant turn before interacting with the app",
            properties: [
                "app": stringProperty("App name, full app path, or unambiguous bundle identifier"),
                "disableDiff": .object(["type": .string("boolean"), "description": .string("Return a full accessibility tree instead of a diff")])
            ],
            required: ["app"]
        ),
        tool(
            name: "click",
            description: "Click an element by index or pixel coordinates from screenshot",
            properties: [
                "app": stringProperty("App name, full app path, or unambiguous bundle identifier"),
                "element_index": integerProperty("Element index to click"),
                "x": numberProperty("X coordinate in screenshot pixel coordinates"),
                "y": numberProperty("Y coordinate in screenshot pixel coordinates"),
                "mouse_button": .object([
                    "type": .string("string"),
                    "description": .string("Mouse button to click. Defaults to left."),
                    "enum": .array([.string("left"), .string("right"), .string("middle")])
                ]),
                "click_count": integerProperty("Number of clicks. Defaults to 1")
            ],
            required: ["app"]
        ),
        tool(
            name: "type_text",
            description: "Type literal text using keyboard input",
            properties: [
                "app": stringProperty("App name, full app path, or unambiguous bundle identifier"),
                "text": stringProperty("Literal text to type")
            ],
            required: ["app", "text"]
        ),
        tool(
            name: "press_key",
            description: "Press a key or key-combination on the keyboard, including modifier and navigation keys.",
            properties: [
                "app": stringProperty("App name, full app path, or unambiguous bundle identifier"),
                "key": stringProperty("Key or key combination to press")
            ],
            required: ["app", "key"]
        ),
        tool(
            name: "scroll",
            description: "Scroll an element in a direction by a number of pages",
            properties: [
                "app": stringProperty("App name, full app path, or unambiguous bundle identifier"),
                "element_index": integerProperty("Element index to scroll"),
                "direction": .object([
                    "type": .string("string"),
                    "description": .string("Scroll direction: up, down, left, or right"),
                    "enum": .array([.string("up"), .string("down"), .string("left"), .string("right")])
                ]),
                "pages": numberProperty("Number of pages to scroll. Fractional values are supported. Defaults to 1")
            ],
            required: ["app", "direction"]
        )
    ]

    private static func tool(
        name: String,
        description: String,
        properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
                "additionalProperties": .bool(false)
            ])
        ])
    }

    private static func stringProperty(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integerProperty(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private static func numberProperty(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }
}

private actor RecordingTransport: ServiceTransport {
    struct Call: Equatable {
        let operation: ServiceOperation
        let arguments: [String: JSONValue]
    }

    private(set) var calls: [Call] = []
    private let result: JSONValue
    private let error: ServiceError?

    init(result: JSONValue = .null, error: ServiceError? = nil) {
        self.result = result
        self.error = error
    }

    func call(operation: ServiceOperation, arguments: [String: JSONValue]) async throws -> JSONValue {
        calls.append(.init(operation: operation, arguments: arguments))
        if let error { throw error }
        return result
    }
}

private enum TestFailure: Error {
    case invalidContent
}
