@preconcurrency import Foundation
import SentientComputerUseCore

public protocol ServiceTransport: Sendable {
    func call(operation: ServiceOperation, arguments: [String: JSONValue]) async throws -> JSONValue
}

public actor MCPServer {
    public static let supportedProtocolVersion = "2025-03-26"

    private let transport: any ServiceTransport
    private var hasNegotiatedInitialization = false
    private var isInitialized = false

    public init(transport: any ServiceTransport) {
        self.transport = transport
    }

    public func handle(_ request: JSONValue) async -> JSONValue? {
        if case let .array(entries) = request {
            return await handleBatch(entries)
        }
        return await handleSingle(request, permitsInitialize: true)
    }

    private func handleBatch(_ entries: [JSONValue]) async -> JSONValue? {
        guard !entries.isEmpty else {
            return Self.error(id: .null, code: -32600, message: "Invalid Request")
        }

        let batchIsAllowed = isInitialized
        var responses: [JSONValue] = []
        for entry in entries {
            let id = Self.validID(in: entry)
            guard !Self.isNotification(entry) else { continue }

            if Self.method(in: entry) == "initialize" || !batchIsAllowed {
                responses.append(Self.error(id: id ?? .null, code: -32600, message: "Invalid Request"))
                continue
            }
            if let response = await handleSingle(entry, permitsInitialize: false) {
                responses.append(response)
            }
        }
        return responses.isEmpty ? nil : .array(responses)
    }

    private func handleSingle(_ request: JSONValue, permitsInitialize: Bool) async -> JSONValue? {
        guard case let .object(envelope) = request,
              envelope["jsonrpc"] == .string("2.0"),
              case let .string(method)? = envelope["method"] else {
            return Self.error(id: .null, code: -32600, message: "Invalid Request")
        }

        guard let id = envelope["id"] else {
            if method == "notifications/initialized", hasNegotiatedInitialization {
                isInitialized = true
            }
            // JSON-RPC notifications never receive a response, including unknown notifications.
            return nil
        }
        guard Self.isValidID(id) else {
            return Self.error(id: .null, code: -32600, message: "Invalid Request")
        }

        switch method {
        case "initialize":
            guard permitsInitialize, !hasNegotiatedInitialization else {
                return Self.error(id: id, code: -32600, message: "Invalid Request")
            }
            guard case let .object(params)? = envelope["params"],
                  case let .string(requestedProtocolVersion)? = params["protocolVersion"],
                  case .object? = params["capabilities"],
                  case let .object(clientInfo)? = params["clientInfo"],
                  case .string? = clientInfo["name"],
                  case .string? = clientInfo["version"] else {
                return Self.error(id: id, code: -32602, message: "Invalid params")
            }
            let negotiatedProtocolVersion = requestedProtocolVersion == Self.supportedProtocolVersion
                ? requestedProtocolVersion
                : Self.supportedProtocolVersion
            hasNegotiatedInitialization = true
            return Self.success(id: id, result: .object([
                "protocolVersion": .string(negotiatedProtocolVersion),
                "capabilities": .object([
                    "tools": .object(["listChanged": .bool(false)])
                ]),
                "serverInfo": .object([
                    "name": .string("sentient-computer-use"),
                    "version": .string("1.0.0")
                ])
            ]))

        case "notifications/initialized":
            return Self.success(id: id, result: .object([:]))

        case "tools/list":
            if let params = envelope["params"], case .object = params {} else if envelope["params"] != nil {
                return Self.error(id: id, code: -32602, message: "Invalid params")
            }
            return Self.success(id: id, result: .object(["tools": .array(Self.tools)]))

        case "tools/call":
            guard case let .object(params)? = envelope["params"],
                  case let .string(name)? = params["name"],
                  let operation = ServiceOperation(rawValue: name) else {
                return Self.error(id: id, code: -32602, message: "Invalid params")
            }

            let arguments: [String: JSONValue]
            if let value = params["arguments"] {
                guard case let .object(object) = value else {
                    return Self.error(id: id, code: -32602, message: "Invalid params")
                }
                arguments = object
            } else {
                arguments = [:]
            }

            do {
                let result = try await transport.call(operation: operation, arguments: arguments)
                return Self.success(id: id, result: Self.toolResult(result, isError: false))
            } catch let serviceError as ServiceError {
                let error: JSONValue = .object([
                    "code": .string(serviceError.code.rawValue),
                    "message": .string(serviceError.message)
                ])
                return Self.success(
                    id: id,
                    result: Self.toolResult(.object(["error": error]), isError: true)
                )
            } catch {
                let internalError: JSONValue = .object([
                    "code": .string(ServiceErrorCode.internalError.rawValue),
                    "message": .string("Internal service error")
                ])
                return Self.success(
                    id: id,
                    result: Self.toolResult(.object(["error": internalError]), isError: true)
                )
            }

        default:
            return Self.error(id: id, code: -32601, message: "Method not found")
        }
    }

    public func handle(_ data: Data) async -> Data? {
        let request: JSONValue
        do {
            request = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            return Self.encode(Self.error(id: .null, code: -32700, message: "Parse error"))
        }
        guard let response = await handle(request) else { return nil }
        return Self.encode(response)
    }

    static var parseErrorData: Data {
        encode(error(id: .null, code: -32700, message: "Parse error")) ?? Data()
    }

    private static func method(in request: JSONValue) -> String? {
        guard case let .object(envelope) = request,
              case let .string(method)? = envelope["method"] else { return nil }
        return method
    }

    private static func isNotification(_ request: JSONValue) -> Bool {
        guard case let .object(envelope) = request,
              envelope["id"] == nil,
              envelope["jsonrpc"] == .string("2.0"),
              case .string? = envelope["method"] else { return false }
        return true
    }

    private static func validID(in request: JSONValue) -> JSONValue? {
        guard case let .object(envelope) = request,
              let id = envelope["id"],
              isValidID(id) else { return nil }
        return id
    }

    private static func isValidID(_ id: JSONValue) -> Bool {
        switch id {
        case .string, .int, .double, .null:
            return true
        case .bool, .array, .object:
            return false
        }
    }

    private static func success(id: JSONValue, result: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result
        ])
    }

    private static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .int(code),
                "message": .string(message)
            ])
        ])
    }

    private static func toolResult(_ value: JSONValue, isError: Bool) -> JSONValue {
        let text: String
        if let data = encode(value), let encoded = String(data: data, encoding: .utf8) {
            text = encoded
        } else {
            text = "{}"
        }
        return .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string(text)])
            ]),
            "structuredContent": value,
            "isError": .bool(isError)
        ])
    }

    private static func encode(_ value: JSONValue) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(value)
    }

    private static let tools: [JSONValue] = [
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
                "disableDiff": .object([
                    "type": .string("boolean"),
                    "description": .string("Return a full accessibility tree instead of a diff")
                ])
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

enum MCPStdio {
    private static let maximumLineSize = 1 * 1024 * 1024

    static func run(input: FileHandle, output: FileHandle, server: MCPServer) async {
        var line = Data()
        var discardingOversizedLine = false

        while !Task.isCancelled {
            let chunk = input.availableData
            guard !chunk.isEmpty else { break }

            for byte in chunk {
                guard !Task.isCancelled else { return }
                if byte == 0x0A {
                    if discardingOversizedLine {
                        await writeParseError(to: output)
                        discardingOversizedLine = false
                    } else {
                        guard await process(line, output: output, server: server) else { return }
                        line.removeAll(keepingCapacity: true)
                    }
                } else if !discardingOversizedLine {
                    if line.count < maximumLineSize {
                        line.append(byte)
                    } else {
                        line.removeAll(keepingCapacity: false)
                        discardingOversizedLine = true
                    }
                }
            }
        }

        guard !Task.isCancelled else { return }
        if discardingOversizedLine {
            await writeParseError(to: output)
        } else if !line.isEmpty {
            _ = await process(line, output: output, server: server)
        }
    }

    private static func process(_ line: Data, output: FileHandle, server: MCPServer) async -> Bool {
        guard let response = await server.handle(line) else { return true }
        return write(response, to: output)
    }

    private static func writeParseError(to output: FileHandle) async {
        _ = write(MCPServer.parseErrorData, to: output)
    }

    private static func write(_ response: Data, to output: FileHandle) -> Bool {
        var framed = response
        framed.append(0x0A)
        do {
            try output.write(contentsOf: framed)
            return true
        } catch {
            return false
        }
    }
}
