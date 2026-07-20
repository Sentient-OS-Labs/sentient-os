import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public enum ServiceOperation: String, Codable, Sendable, Equatable {
    case listApps = "list_apps"
    case getAppState = "get_app_state"
    case click
    case typeText = "type_text"
    case pressKey = "press_key"
    case scroll
}

public struct ServiceRequest: Codable, Sendable, Equatable {
    public let id: String
    public let operation: ServiceOperation
    public let arguments: [String: JSONValue]

    public init(id: String, operation: ServiceOperation, arguments: [String: JSONValue]) {
        self.id = id
        self.operation = operation
        self.arguments = arguments
    }
}

public enum ServiceErrorCode: String, Codable, Sendable, Equatable {
    case permissionDeniedAccessibility = "permission_denied_accessibility"
    case permissionDeniedScreenRecording = "permission_denied_screen_recording"
    case applicationNotFound = "application_not_found"
    case elementNotFound = "element_not_found"
    case staleSnapshot = "stale_snapshot"
    case unsupportedAction = "unsupported_action"
    case invalidRequest = "invalid_request"
    case captureFailed = "capture_failed"
    case internalError = "internal_error"
}

public struct ServiceError: Error, Codable, Sendable, Equatable {
    public let code: ServiceErrorCode
    public let message: String

    public init(code: ServiceErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum ServiceResponse: Codable, Sendable, Equatable {
    case success(id: String, result: JSONValue)
    case failure(id: String, ServiceError)

    public var id: String {
        switch self {
        case .success(let id, _), .failure(let id, _):
            return id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case result
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasResult = container.contains(.result)
        let hasError = container.contains(.error)

        switch (hasResult, hasError) {
        case (true, false):
            self = .success(
                id: try container.decode(String.self, forKey: .id),
                result: try container.decode(JSONValue.self, forKey: .result)
            )
        case (false, true):
            self = .failure(
                id: try container.decode(String.self, forKey: .id),
                try container.decode(ServiceError.self, forKey: .error)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "A service response must contain exactly one of result or error"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .success(let id, let result):
            try container.encode(id, forKey: .id)
            try container.encode(result, forKey: .result)
        case .failure(let id, let error):
            try container.encode(id, forKey: .id)
            try container.encode(error, forKey: .error)
        }
    }
}
