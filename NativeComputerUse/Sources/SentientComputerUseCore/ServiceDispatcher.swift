import ApplicationServices
import CoreGraphics
import Foundation

protocol PermissionChecking {
    func hasAccessibilityPermission() -> Bool
    func hasScreenRecordingPermission() -> Bool
}

struct SystemPermissionChecker: PermissionChecking {
    func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }
}

public final class ServiceDispatcher {
    private let catalog: any ApplicationCataloging
    private let inspector: any AccessibilityInspecting
    private let elementResolver: any SnapshotElementReferenceResolving
    private let input: any InputControlling
    private let permissions: any PermissionChecking
    private let screenCapturer: any ScreenCapturing

    public convenience init() {
        let provider = SystemAXProvider()
        let inspector = AccessibilityInspector(provider: provider)
        let input = InputController(
            events: SystemEventPoster(),
            actions: SystemAccessibilityActionPerformer { reference in
                try provider.resolve(reference.axReference)
            }
        )
        self.init(
            catalog: ApplicationCatalog(),
            inspector: inspector,
            elementResolver: inspector,
            input: input,
            permissions: SystemPermissionChecker(),
            screenCapturer: ScreenCapturer()
        )
    }

    init(
        catalog: any ApplicationCataloging,
        inspector: any AccessibilityInspecting,
        elementResolver: any SnapshotElementReferenceResolving,
        input: any InputControlling,
        permissions: any PermissionChecking,
        screenCapturer: any ScreenCapturing
    ) {
        self.catalog = catalog
        self.inspector = inspector
        self.elementResolver = elementResolver
        self.input = input
        self.permissions = permissions
        self.screenCapturer = screenCapturer
    }

    public func handle(_ request: ServiceRequest) async -> ServiceResponse {
        do {
            let result = try await dispatch(request)
            return .success(id: request.id, result: result)
        } catch let error as ServiceError {
            return .failure(id: request.id, error)
        } catch {
            return .failure(id: request.id, ServiceError(code: .internalError, message: "Internal service error"))
        }
    }

    private func dispatch(_ request: ServiceRequest) async throws -> JSONValue {
        switch request.operation {
        case .listApps:
            try validate(arguments: request.arguments, allowed: [])
            return .array(try catalog.applications().map(jsonValue))
        case .getAppState:
            let app = try appArgument(request.arguments, allowed: ["app", "disable_diff"])
            _ = try optionalBool("disable_diff", in: request.arguments)
            try requireAccessibility()
            try requireScreenRecording()
            let application = try catalog.resolve(app)
            let snapshot = try inspector.snapshot(
                app: application,
                maxDepth: AccessibilityInspector.defaultMaxDepth,
                maxElements: AccessibilityInspector.defaultMaxElements
            )
            do {
                let capture = try await screenCapturer.captureMainDisplay()
                return .object([
                    "app": try jsonValue(application),
                    "snapshot": try jsonValue(snapshot),
                    "capture": try jsonValue(capture)
                ])
            } catch {
                throw ServiceError(code: .captureFailed, message: "Unable to capture the display")
            }
        case .click:
            let parsed = try parseClick(request.arguments)
            try requireAccessibility()
            let element = try parsed.snapshot.map { try elementResolver.resolveElementReference(snapshotToken: $0, index: parsed.elementIndex!) }
            try input.click(element: element, coordinate: parsed.coordinate, button: parsed.button, count: parsed.count)
            return successResult
        case .typeText:
            let app = try appArgument(request.arguments, allowed: ["app", "text"])
            _ = app
            let text = try requiredString("text", in: request.arguments)
            try requireAccessibility()
            try input.typeText(text)
            return successResult
        case .pressKey:
            let app = try appArgument(request.arguments, allowed: ["app", "key"])
            _ = app
            let key = try requiredString("key", in: request.arguments)
            try requireAccessibility()
            try input.pressKey(key)
            return successResult
        case .scroll:
            let parsed = try parseScroll(request.arguments)
            try requireAccessibility()
            try input.scroll(direction: parsed.direction, pages: parsed.pages, anchor: parsed.anchor)
            return successResult
        }
    }

    private var successResult: JSONValue { .object(["ok": .bool(true)]) }

    private func parseClick(_ arguments: [String: JSONValue]) throws -> (snapshot: UUID?, elementIndex: Int?, coordinate: CGPoint?, button: MouseButton, count: Int) {
        try validate(arguments: arguments, allowed: ["app", "snapshot_token", "element_index", "x", "y", "mouse_button", "click_count"])
        _ = try requiredString("app", in: arguments)
        let snapshot = try optionalUUID("snapshot_token", in: arguments)
        let elementIndex = try optionalInt("element_index", in: arguments)
        let x = try optionalNumber("x", in: arguments)
        let y = try optionalNumber("y", in: arguments)
        let coordinate = try coordinate(x: x, y: y)
        guard (snapshot == nil) == (elementIndex == nil), snapshot != nil || coordinate != nil else { throw invalidRequest }
        let button = try mouseButton(arguments["mouse_button"])
        let count = try optionalInt("click_count", in: arguments) ?? 1
        return (snapshot, elementIndex, coordinate, button, count)
    }

    private func parseScroll(_ arguments: [String: JSONValue]) throws -> (direction: ScrollDirection, pages: Int, anchor: CGPoint?) {
        try validate(arguments: arguments, allowed: ["app", "direction", "pages", "x", "y"])
        _ = try requiredString("app", in: arguments)
        let direction = try scrollDirection(arguments["direction"])
        let pages = try optionalInt("pages", in: arguments) ?? 1
        let anchor = try coordinate(x: optionalNumber("x", in: arguments), y: optionalNumber("y", in: arguments))
        return (direction, pages, anchor)
    }

    private func requireAccessibility() throws {
        guard permissions.hasAccessibilityPermission() else {
            throw ServiceError(code: .permissionDeniedAccessibility, message: "Accessibility permission is required")
        }
    }

    private func requireScreenRecording() throws {
        guard permissions.hasScreenRecordingPermission() else {
            throw ServiceError(code: .permissionDeniedScreenRecording, message: "Screen Recording permission is required")
        }
    }

    private func validate(arguments: [String: JSONValue], allowed: Set<String>) throws {
        guard Set(arguments.keys).isSubset(of: allowed) else { throw invalidRequest }
    }

    private func appArgument(_ arguments: [String: JSONValue], allowed: Set<String>) throws -> String {
        try validate(arguments: arguments, allowed: allowed)
        return try requiredString("app", in: arguments)
    }

    private func requiredString(_ name: String, in arguments: [String: JSONValue]) throws -> String {
        guard case let .string(value)? = arguments[name], !value.isEmpty else { throw invalidRequest }
        return value
    }

    private func optionalBool(_ name: String, in arguments: [String: JSONValue]) throws -> Bool? {
        guard let value = arguments[name] else { return nil }
        guard case let .bool(bool) = value else { throw invalidRequest }
        return bool
    }

    private func optionalUUID(_ name: String, in arguments: [String: JSONValue]) throws -> UUID? {
        guard let value = arguments[name] else { return nil }
        guard case let .string(string) = value, let uuid = UUID(uuidString: string) else { throw invalidRequest }
        return uuid
    }

    private func optionalInt(_ name: String, in arguments: [String: JSONValue]) throws -> Int? {
        guard let value = arguments[name] else { return nil }
        guard case let .int(integer) = value else { throw invalidRequest }
        return integer
    }

    private func optionalNumber(_ name: String, in arguments: [String: JSONValue]) throws -> CGFloat? {
        guard let value = arguments[name] else { return nil }
        let number: Double
        switch value {
        case .int(let integer): number = Double(integer)
        case .double(let double): number = double
        default: throw invalidRequest
        }
        guard number.isFinite else { throw invalidRequest }
        return CGFloat(number)
    }

    private func coordinate(x: CGFloat?, y: CGFloat?) throws -> CGPoint? {
        guard x != nil || y != nil else { return nil }
        guard let x, let y else { throw invalidRequest }
        return CGPoint(x: x, y: y)
    }

    private func mouseButton(_ value: JSONValue?) throws -> MouseButton {
        guard let value else { return .left }
        guard case let .string(button) = value else { throw invalidRequest }
        switch button {
        case "left": return .left
        case "right": return .right
        case "middle": return .middle
        default: throw invalidRequest
        }
    }

    private func scrollDirection(_ value: JSONValue?) throws -> ScrollDirection {
        guard case let .string(direction)? = value else { throw invalidRequest }
        switch direction {
        case "up": return .up
        case "down": return .down
        case "left": return .left
        case "right": return .right
        default: throw invalidRequest
        }
    }

    private func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    private var invalidRequest: ServiceError {
        ServiceError(code: .invalidRequest, message: "Invalid request")
    }
}
