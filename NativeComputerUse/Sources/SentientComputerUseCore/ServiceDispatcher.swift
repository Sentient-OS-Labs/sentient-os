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
            let app = try appArgument(request.arguments, allowed: ["app", "disableDiff"])
            _ = try optionalBool("disableDiff", in: request.arguments)
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
            let element: SnapshotElementReference?
            if let index = parsed.elementIndex {
                let application = try catalog.resolve(parsed.app)
                element = try elementResolver.resolveLatestElementReference(app: application, index: index)
            } else {
                element = nil
            }
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
            try validateKey(key)
            try requireAccessibility()
            try input.pressKey(key)
            return successResult
        case .scroll:
            let parsed = try parseScroll(request.arguments)
            try requireAccessibility()
            let anchor: CGPoint?
            if let index = parsed.elementIndex {
                let application = try catalog.resolve(parsed.app)
                let element = try elementResolver.latestElement(app: application, index: index)
                guard let frame = element.frame else {
                    throw ServiceError(code: .elementNotFound, message: "Element has no frame")
                }
                anchor = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
            } else {
                anchor = nil
            }
            try input.scroll(direction: parsed.direction, pages: parsed.pages, anchor: anchor)
            return successResult
        }
    }

    private var successResult: JSONValue { .object(["ok": .bool(true)]) }

    private func parseClick(_ arguments: [String: JSONValue]) throws -> (app: String, elementIndex: Int?, coordinate: CGPoint?, button: MouseButton, count: Int) {
        try validate(arguments: arguments, allowed: ["app", "element_index", "x", "y", "mouse_button", "click_count"])
        let app = try requiredString("app", in: arguments)
        let elementIndex = try optionalInt("element_index", in: arguments)
        let x = try optionalNumber("x", in: arguments)
        let y = try optionalNumber("y", in: arguments)
        let coordinate = try coordinate(x: x, y: y)
        guard elementIndex != nil || coordinate != nil else { throw invalidRequest }
        let button = try InputRequestValidator.mouseButton(try optionalString("mouse_button", in: arguments))
        let count = try optionalInt("click_count", in: arguments) ?? 1
        try InputRequestValidator.clickCount(count)
        return (app, elementIndex, coordinate, button, count)
    }

    private func parseScroll(_ arguments: [String: JSONValue]) throws -> (app: String, elementIndex: Int?, direction: ScrollDirection, pages: Int) {
        try validate(arguments: arguments, allowed: ["app", "element_index", "direction", "pages"])
        let app = try requiredString("app", in: arguments)
        let elementIndex = try optionalInt("element_index", in: arguments)
        let direction = try InputRequestValidator.scrollDirection(try optionalString("direction", in: arguments))
        let pages = try optionalInt("pages", in: arguments) ?? 1
        try InputRequestValidator.scrollPages(pages)
        return (app, elementIndex, direction, pages)
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

    private func optionalString(_ name: String, in arguments: [String: JSONValue]) throws -> String? {
        guard let value = arguments[name] else { return nil }
        guard case let .string(string) = value else { throw invalidRequest }
        return string
    }

    private func coordinate(x: CGFloat?, y: CGFloat?) throws -> CGPoint? {
        guard x != nil || y != nil else { return nil }
        guard let x, let y else { throw invalidRequest }
        return CGPoint(x: x, y: y)
    }

    private func validateKey(_ key: String) throws {
        do {
            _ = try InputRequestValidator.key(key)
        } catch {
            throw invalidRequest
        }
    }

    private func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    private var invalidRequest: ServiceError {
        ServiceError(code: .invalidRequest, message: "Invalid request")
    }
}
