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

    func testInitializeFallsBackToSupportedProtocolVersion() async throws {
        let server = MCPServer(transport: RecordingTransport())

        let response = await server.handle(initializeRequest(id: .int(2), protocolVersion: "2099-01-01"))

        guard case let .object(envelope)? = response,
              case let .object(result)? = envelope["result"] else {
            return XCTFail("Expected initialize result")
        }
        XCTAssertEqual(result["protocolVersion"], .string("2025-03-26"))
    }

    func testInitializeRejectsMissingRequiredClientFields() async throws {
        let server = MCPServer(transport: RecordingTransport())
        let cases: [JSONValue] = [
            .object(["protocolVersion": .string("2025-03-26"), "clientInfo": Self.validClientInfo]),
            .object(["protocolVersion": .string("2025-03-26"), "capabilities": .object([:])]),
            .object([
                "protocolVersion": .string("2025-03-26"),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("tests")])
            ]),
            .object([
                "protocolVersion": .string("2025-03-26"),
                "capabilities": .object([:]),
                "clientInfo": .object(["version": .string("1")])
            ])
        ]

        for (index, params) in cases.enumerated() {
            let id = JSONValue.int(20 + index)
            let response = await server.handle(request(id: id, method: "initialize", params: params))
            XCTAssertEqual(response, jsonRPCError(id: id, code: -32602, message: "Invalid params"))
        }
    }

    func testInitializeRejectsWrongTypedClientFields() async throws {
        let server = MCPServer(transport: RecordingTransport())
        let cases: [JSONValue] = [
            .object([
                "protocolVersion": .int(1),
                "capabilities": .object([:]),
                "clientInfo": Self.validClientInfo
            ]),
            .object([
                "protocolVersion": .string("2025-03-26"),
                "capabilities": .array([]),
                "clientInfo": Self.validClientInfo
            ]),
            .object([
                "protocolVersion": .string("2025-03-26"),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .bool(true), "version": .string("1")])
            ]),
            .object([
                "protocolVersion": .string("2025-03-26"),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("tests"), "version": .int(1)])
            ])
        ]

        for (index, params) in cases.enumerated() {
            let id = JSONValue.int(30 + index)
            let response = await server.handle(request(id: id, method: "initialize", params: params))
            XCTAssertEqual(response, jsonRPCError(id: id, code: -32602, message: "Invalid params"))
        }
    }

    func testListsExactlyTheSixApprovedSkyCompatibleTools() async throws {
        let server = MCPServer(transport: RecordingTransport())
        await completeInitialization(server, id: 3)

        let response = await server.handle(request(id: .string("tools"), method: "tools/list", params: .object([:])))

        XCTAssertEqual(response, .object([
            "jsonrpc": .string("2.0"),
            "id": .string("tools"),
            "result": .object(["tools": .array(Self.expectedTools)])
        ]))
    }

    func testScrollPagesSchemaMatchesIntegralServiceBounds() async throws {
        let server = MCPServer(transport: RecordingTransport())
        await completeInitialization(server, id: 3)

        let response = await server.handle(request(id: .int(4), method: "tools/list", params: .object([:])))

        guard case let .object(envelope)? = response,
              case let .object(result)? = envelope["result"],
              case let .array(tools)? = result["tools"],
              let scroll = tools.first(where: {
                  guard case let .object(tool) = $0 else { return false }
                  return tool["name"] == .string("scroll")
              }),
              case let .object(scrollObject) = scroll,
              case let .object(schema)? = scrollObject["inputSchema"],
              case let .object(properties)? = schema["properties"] else {
            return XCTFail("Expected scroll input schema")
        }
        XCTAssertEqual(properties["pages"], .object([
            "type": .string("integer"),
            "description": .string("Number of pages to scroll. Defaults to 1"),
            "minimum": .int(1),
            "maximum": .int(10)
        ]))
    }

    func testToolCallForwardsOperationAndArgumentsWithoutRewriting() async throws {
        let transport = RecordingTransport(result: .object(["ok": .bool(true)]))
        let server = MCPServer(transport: transport)
        await completeInitialization(server, id: 7)
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
        await completeInitialization(server, id: 8)

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

    func testArrayToolResultWrapsStructuredContentInAnObject() async throws {
        let apps: JSONValue = .array([.object(["name": .string("Notes")])])
        let server = MCPServer(transport: RecordingTransport(result: apps))
        await completeInitialization(server, id: 90)

        let response = await server.handle(request(
            id: .int(91),
            method: "tools/call",
            params: .object(["name": .string("list_apps"), "arguments": .object([:])])
        ))

        guard case let .object(envelope)? = response,
              case let .object(result)? = envelope["result"] else {
            return XCTFail("Expected an MCP tool result")
        }
        XCTAssertEqual(result["structuredContent"], .object(["result": apps]))
        XCTAssertEqual(try decodedTextContent(result), apps)
    }

    func testToolDescriptionsAdvertiseOnlyImplementedIntelBehavior() async throws {
        let server = MCPServer(transport: RecordingTransport())
        await completeInitialization(server, id: 92)

        let response = await server.handle(request(id: .int(93), method: "tools/list", params: .object([:])))
        guard case let .object(envelope)? = response,
              case let .object(result)? = envelope["result"],
              case let .array(tools)? = result["tools"] else {
            return XCTFail("Expected tools")
        }
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(tools), encoding: .utf8))
        XCTAssertFalse(encoded.contains("last 14 days"))
        XCTAssertFalse(encoded.contains("instead of a diff"))
        XCTAssertTrue(encoded.contains("currently running"))
        XCTAssertTrue(encoded.contains("always returns a bounded full snapshot"))
    }

    func testUnknownMethodReturnsMethodNotFound() async throws {
        let server = MCPServer(transport: RecordingTransport())
        await completeInitialization(server, id: 9)

        let response = await server.handle(request(id: .int(10), method: "resources/list", params: .object([:])))

        XCTAssertEqual(response, jsonRPCError(id: .int(10), code: -32601, message: "Method not found"))
    }

    func testMalformedToolCallReturnsInvalidParams() async throws {
        let server = MCPServer(transport: RecordingTransport())
        await completeInitialization(server, id: 10)

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

    func testRejectsInvalidJSONRPCIdentifierTypesWithNullErrorID() async throws {
        let server = MCPServer(transport: RecordingTransport())
        let invalidIDs: [JSONValue] = [.bool(true), .array([]), .object([:])]

        for id in invalidIDs {
            let response = await server.handle(request(id: id, method: "resources/list", params: .object([:])))
            XCTAssertEqual(response, jsonRPCError(id: .null, code: -32600, message: "Invalid Request"))
        }
    }

    func testAcceptsStringNumberAndNullJSONRPCIdentifiers() async throws {
        let server = MCPServer(transport: RecordingTransport())
        await completeInitialization(server, id: 6)
        let validIDs: [JSONValue] = [.string("request"), .int(7), .double(7.5), .null]

        for id in validIDs {
            let response = await server.handle(request(id: id, method: "resources/list", params: .object([:])))
            XCTAssertEqual(response, jsonRPCError(id: id, code: -32601, message: "Method not found"))
        }
    }

    func testFreshServerRejectsToolRequestsWithoutCallingTransport() async throws {
        let transport = RecordingTransport(result: .array([]))
        let server = MCPServer(transport: transport)

        let listResponse = await server.handle(request(id: .int(35), method: "tools/list", params: .object([:])))
        let callResponse = await server.handle(request(
            id: .int(36),
            method: "tools/call",
            params: .object(["name": .string("list_apps"), "arguments": .object([:])])
        ))
        let calls = await transport.calls

        XCTAssertEqual(listResponse, jsonRPCError(id: .int(35), code: -32600, message: "Invalid Request"))
        XCTAssertEqual(callResponse, jsonRPCError(id: .int(36), code: -32600, message: "Invalid Request"))
        XCTAssertEqual(calls, [])
    }

    func testNegotiatedServerRejectsToolsUntilInitializedNotificationWithoutCallingTransport() async throws {
        let transport = RecordingTransport(result: .array([]))
        let server = MCPServer(transport: transport)
        _ = await server.handle(initializeRequest(id: .int(37)))

        let listResponse = await server.handle(request(id: .int(38), method: "tools/list", params: .object([:])))
        let callResponse = await server.handle(request(
            id: .int(39),
            method: "tools/call",
            params: .object(["name": .string("list_apps"), "arguments": .object([:])])
        ))
        let calls = await transport.calls

        XCTAssertEqual(listResponse, jsonRPCError(id: .int(38), code: -32600, message: "Invalid Request"))
        XCTAssertEqual(callResponse, jsonRPCError(id: .int(39), code: -32600, message: "Invalid Request"))
        XCTAssertEqual(calls, [])
    }

    func testBatchAfterInitializationReturnsOnlyRequestResponses() async throws {
        let transport = RecordingTransport(result: .array([]))
        let server = MCPServer(transport: transport)
        await completeInitialization(server, id: 40)

        let response = await server.handle(.array([
            request(id: .int(41), method: "resources/list", params: .object([:])),
            .object([
                "jsonrpc": .string("2.0"),
                "method": .string("notifications/unknown")
            ]),
            request(
                id: .string("apps"),
                method: "tools/call",
                params: .object(["name": .string("list_apps"), "arguments": .object([:])])
            )
        ]))

        guard case let .array(responses)? = response else {
            return XCTFail("Expected a JSON-RPC batch response")
        }
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(responses[0], jsonRPCError(id: .int(41), code: -32601, message: "Method not found"))
        guard case let .object(toolEnvelope) = responses[1] else {
            return XCTFail("Expected tool response")
        }
        XCTAssertEqual(toolEnvelope["id"], .string("apps"))
    }

    func testAllNotificationBatchProducesNoResponse() async throws {
        let server = MCPServer(transport: RecordingTransport())
        await completeInitialization(server, id: 50)

        let response = await server.handle(.array([
            .object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]),
            .object(["jsonrpc": .string("2.0"), "method": .string("notifications/unknown")])
        ]))

        XCTAssertNil(response)
    }

    func testEmptyBatchReturnsInvalidRequest() async throws {
        let server = MCPServer(transport: RecordingTransport())
        await completeInitialization(server, id: 60)

        let response = await server.handle(.array([]))

        XCTAssertEqual(response, jsonRPCError(id: .null, code: -32600, message: "Invalid Request"))
    }

    func testInvalidBatchEntriesAreNotMistakenForNotifications() async throws {
        let server = MCPServer(transport: RecordingTransport())
        await completeInitialization(server, id: 65)

        let response = await server.handle(.array([
            .bool(true),
            .object(["jsonrpc": .string("2.0")])
        ]))

        let invalid = jsonRPCError(id: .null, code: -32600, message: "Invalid Request")
        XCTAssertEqual(response, .array([invalid, invalid]))
    }

    func testInitializeInsideBatchIsRejectedAndNotProcessed() async throws {
        let server = MCPServer(transport: RecordingTransport())
        await completeInitialization(server, id: 70)

        let response = await server.handle(.array([
            initializeRequest(id: .int(71), protocolVersion: "2099-01-01")
        ]))

        XCTAssertEqual(response, .array([
            jsonRPCError(id: .int(71), code: -32600, message: "Invalid Request")
        ]))
    }

    func testBatchWaitsForInitializedNotification() async throws {
        let server = MCPServer(transport: RecordingTransport())
        _ = await server.handle(initializeRequest(id: .int(80)))
        let batch: JSONValue = .array([
            request(id: .int(81), method: "resources/list", params: .object([:]))
        ])

        let beforeNotification = await server.handle(batch)
        _ = await server.handle(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized")
        ]))
        let afterNotification = await server.handle(batch)

        XCTAssertEqual(beforeNotification, .array([
            jsonRPCError(id: .int(81), code: -32600, message: "Invalid Request")
        ]))
        XCTAssertEqual(afterNotification, .array([
            jsonRPCError(id: .int(81), code: -32601, message: "Method not found")
        ]))
    }

    func testOversizedToolResponseBecomesBoundedStructuredInternalError() async throws {
        let result: JSONValue = .object(["blob": .string(String(repeating: "x", count: 600_000))])
        let server = MCPServer(transport: RecordingTransport(result: result))
        await completeInitialization(server, id: 100)
        let request = request(
            id: .int(101),
            method: "tools/call",
            params: .object(["name": .string("list_apps"), "arguments": .object([:])])
        )

        let handledData = await server.handle(try JSONEncoder().encode(request))
        let responseData = try XCTUnwrap(handledData)
        XCTAssertLessThanOrEqual(responseData.count + 1, MCPServer.maximumResponseLineSize)

        let response = try JSONDecoder().decode(JSONValue.self, from: responseData)
        guard case let .object(envelope) = response,
              envelope["id"] == .int(101),
              case let .object(toolResult)? = envelope["result"],
              case let .object(structured)? = toolResult["structuredContent"],
              case let .object(error)? = structured["error"] else {
            return XCTFail("Expected a structured MCP tool error")
        }
        XCTAssertEqual(toolResult["isError"], .bool(true))
        XCTAssertEqual(error["code"], .string(ServiceErrorCode.internalError.rawValue))
        XCTAssertEqual(try decodedTextContent(toolResult), .object(["error": .object(error)]))
    }

    func testNearLimitToolResponseIsReturnedUnchanged() async throws {
        let result: JSONValue = .object(["blob": .string(String(repeating: "x", count: 500_000))])
        let server = MCPServer(transport: RecordingTransport(result: result))
        await completeInitialization(server, id: 102)
        let request = request(
            id: .int(103),
            method: "tools/call",
            params: .object(["name": .string("list_apps"), "arguments": .object([:])])
        )
        let handledExpected = await server.handle(request)
        let expected = try XCTUnwrap(handledExpected)

        let handledData = await server.handle(try JSONEncoder().encode(request))
        let responseData = try XCTUnwrap(handledData)

        XCTAssertGreaterThan(responseData.count, 950_000)
        XCTAssertLessThanOrEqual(responseData.count + 1, MCPServer.maximumResponseLineSize)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: responseData), expected)
    }

    func testWireNotificationRemainsSilent() async throws {
        let server = MCPServer(transport: RecordingTransport())
        let notification: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/unknown")
        ])

        let response = await server.handle(try JSONEncoder().encode(notification))
        XCTAssertNil(response)
    }

    private func request(id: JSONValue, method: String, params: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "method": .string(method),
            "params": params
        ])
    }

    private func initializeRequest(id: JSONValue, protocolVersion: String = "2025-03-26") -> JSONValue {
        request(
            id: id,
            method: "initialize",
            params: .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": Self.validClientInfo
            ])
        )
    }

    private func completeInitialization(_ server: MCPServer, id: Int) async {
        _ = await server.handle(initializeRequest(id: .int(id)))
        _ = await server.handle(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized")
        ]))
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
            description: "List the GUI applications that are currently running on this computer",
            properties: [:],
            required: []
        ),
        tool(
            name: "get_app_state",
            description: "Start an app use session if needed, then get the state of the app's key window and return a screenshot and accessibility tree. This must be called once per assistant turn before interacting with the app",
            properties: [
                "app": stringProperty("App name, full app path, or unambiguous bundle identifier"),
                "disableDiff": .object(["type": .string("boolean"), "description": .string("Compatibility flag; Intel always returns a bounded full snapshot")])
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
                "pages": .object([
                    "type": .string("integer"),
                    "description": .string("Number of pages to scroll. Defaults to 1"),
                    "minimum": .int(1),
                    "maximum": .int(10)
                ])
            ],
            required: ["app", "direction"]
        )
    ]

    private static let validClientInfo: JSONValue = .object([
        "name": .string("tests"),
        "version": .string("1")
    ])

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
