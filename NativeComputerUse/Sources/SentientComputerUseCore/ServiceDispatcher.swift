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
    private let applicationActivator: any ApplicationActivating
    private let permissions: any PermissionChecking
    private let screenCapturer: any ScreenCapturing
    private var didCleanup = false

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
            applicationActivator: SystemApplicationActivator(),
            permissions: SystemPermissionChecker(),
            screenCapturer: ScreenCapturer()
        )
    }

    init(
        catalog: any ApplicationCataloging,
        inspector: any AccessibilityInspecting,
        elementResolver: any SnapshotElementReferenceResolving,
        input: any InputControlling,
        applicationActivator: any ApplicationActivating,
        permissions: any PermissionChecking,
        screenCapturer: any ScreenCapturing
    ) {
        self.catalog = catalog
        self.inspector = inspector
        self.elementResolver = elementResolver
        self.input = input
        self.applicationActivator = applicationActivator
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

    /// Task 5's service-loop owner calls this once when the NDJSON loop exits.
    /// Repeated calls are intentionally harmless and do not duplicate capture cleanup.
    public func cleanup() {
        guard !didCleanup else { return }
        didCleanup = true
        screenCapturer.cleanup()
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
            try activate(application)
            let capture: CaptureResult
            do {
                capture = try await screenCapturer.captureMainDisplay()
            } catch {
                throw ServiceError(code: .captureFailed, message: "Unable to capture the display")
            }
            // Build and commit the AX snapshot only after capture succeeds. A failed capture must
            // leave the latest visible element indexes usable by a subsequent action.
            let snapshot = try inspector.snapshot(
                app: application,
                maxDepth: AccessibilityInspector.defaultMaxDepth,
                maxElements: AccessibilityInspector.defaultMaxElements
            )
            return .object([
                "app": try jsonValue(application),
                "snapshot": try jsonValue(snapshot),
                "capture": try jsonValue(capture)
            ])
        case .click:
            let parsed = try parseClick(request.arguments)
            if let coordinate = parsed.coordinate {
                try input.validate(coordinate: coordinate)
            }
            try requireAccessibility()
            let application = try catalog.resolve(parsed.app)
            try activate(application)
            let element: SnapshotElementReference?
            if let index = parsed.elementIndex {
                element = try elementResolver.resolveLatestElementReference(app: application, index: index)
            } else {
                element = nil
            }
            try input.click(element: element, coordinate: parsed.coordinate, button: parsed.button, count: parsed.count)
            return successResult
        case .typeText:
            let app = try appArgument(request.arguments, allowed: ["app", "text"])
            let text = try requiredString("text", in: request.arguments)
            try requireAccessibility()
            let application = try catalog.resolve(app)
            try activate(application)
            try input.typeText(text)
            return successResult
        case .pressKey:
            let app = try appArgument(request.arguments, allowed: ["app", "key"])
            let key = try requiredString("key", in: request.arguments)
            try validateKey(key)
            try requireAccessibility()
            let application = try catalog.resolve(app)
            try activate(application)
            try input.pressKey(key)
            return successResult
        case .scroll:
            let parsed = try parseScroll(request.arguments)
            try requireAccessibility()
            let application = try catalog.resolve(parsed.app)
            let anchor = try scrollAnchor(for: parsed, application: application)
            if let anchor {
                try input.validate(coordinate: anchor)
            }
            try activate(application)
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

    private func scrollAnchor(
        for parsed: (app: String, elementIndex: Int?, direction: ScrollDirection, pages: Int),
        application: ApplicationDescriptor
    ) throws -> CGPoint? {
        guard let index = parsed.elementIndex else { return nil }
        let element = try elementResolver.latestElement(app: application, index: index)
        guard let frame = element.frame else {
            throw ServiceError(code: .elementNotFound, message: "Element has no frame")
        }
        return CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
    }

    private func activate(_ application: ApplicationDescriptor) throws {
        guard applicationActivator.activateAndVerifyFrontmost(application) else {
            throw ServiceError(code: .applicationNotFound, message: "Application could not be focused")
        }
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
        _ = try InputRequestValidator.key(key)
    }

    private func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    private var invalidRequest: ServiceError {
        ServiceError(code: .invalidRequest, message: "Invalid request")
    }
}
