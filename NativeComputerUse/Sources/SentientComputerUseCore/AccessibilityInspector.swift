import ApplicationServices
import Foundation

public struct AXElementReference: Hashable, Sendable {
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}

public struct SnapshotFrame: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct AXElementAttributes: Sendable, Equatable {
    public let role: String?
    public let title: String?
    public let value: String?
    public let frame: SnapshotFrame?
    public let actions: [String]

    public init(role: String?, title: String?, value: String?, frame: SnapshotFrame?, actions: [String]) {
        self.role = role
        self.title = title
        self.value = value
        self.frame = frame
        self.actions = actions
    }
}

public protocol AXProviding {
    func rootElement(for app: ApplicationDescriptor) throws -> AXElementReference
    func attributes(for element: AXElementReference) throws -> AXElementAttributes
    func children(of element: AXElementReference) throws -> [AXElementReference]
}

public struct SnapshotElement: Codable, Sendable, Equatable {
    public let index: Int
    public let role: String?
    public let title: String?
    public let value: String?
    public let frame: SnapshotFrame?
    public let actions: [String]

    public init(index: Int, role: String?, title: String?, value: String?, frame: SnapshotFrame?, actions: [String]) {
        self.index = index
        self.role = role
        self.title = title
        self.value = value
        self.frame = frame
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey {
        case index
        case role
        case title
        case value
        case frame
        case actions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        frame = try container.decodeIfPresent(SnapshotFrame.self, forKey: .frame)
        actions = try container.decodeIfPresent([String].self, forKey: .actions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(frame, forKey: .frame)
        if !actions.isEmpty {
            try container.encode(actions, forKey: .actions)
        }
    }
}

public struct AccessibilitySnapshot: Codable, Sendable, Equatable {
    public let token: UUID
    public let app: ApplicationDescriptor
    public let text: String
    public let elements: [SnapshotElement]

    public init(token: UUID, app: ApplicationDescriptor, text: String, elements: [SnapshotElement]) {
        self.token = token
        self.app = app
        self.text = text
        self.elements = elements
    }
}

public protocol AccessibilityInspecting {
    func snapshot(app: ApplicationDescriptor, maxDepth: Int, maxElements: Int) throws -> AccessibilitySnapshot
    func element(snapshotToken: UUID, index: Int) throws -> SnapshotElement
}

public final class AccessibilityInspector: AccessibilityInspecting {
    public static let defaultMaxDepth = 12
    public static let defaultMaxElements = 500

    private struct CachedSnapshot {
        let token: UUID
        let elements: [SnapshotElement]
        let references: [AXElementReference]
    }

    private let provider: any AXProviding
    private var snapshotsByProcess: [Int32: CachedSnapshot] = [:]

    public init(provider: any AXProviding = SystemAXProvider()) {
        self.provider = provider
    }

    public func snapshot(
        app: ApplicationDescriptor,
        maxDepth: Int = AccessibilityInspector.defaultMaxDepth,
        maxElements: Int = AccessibilityInspector.defaultMaxElements
    ) throws -> AccessibilitySnapshot {
        let root = try provider.rootElement(for: app)
        let depthLimit = max(0, maxDepth)
        let elementLimit = max(0, maxElements)
        var queue: [(element: AXElementReference, depth: Int)] = [(root, 0)]
        var cursor = 0
        var visited = Set<AXElementReference>()
        var elements: [SnapshotElement] = []
        var references: [AXElementReference] = []

        while cursor < queue.count, elements.count < elementLimit {
            let item = queue[cursor]
            cursor += 1
            guard visited.insert(item.element).inserted else { continue }

            let attributes = try provider.attributes(for: item.element)
            let element = SnapshotElement(
                index: elements.count,
                role: Self.normalized(attributes.role),
                title: Self.normalized(attributes.title),
                value: Self.normalized(attributes.value),
                frame: attributes.frame,
                actions: attributes.actions.compactMap(Self.normalized)
            )
            elements.append(element)
            references.append(item.element)

            if item.depth < depthLimit {
                queue.append(contentsOf: try provider.children(of: item.element).map { ($0, item.depth + 1) })
            }
        }

        let token = UUID()
        snapshotsByProcess[app.processIdentifier] = CachedSnapshot(token: token, elements: elements, references: references)
        return AccessibilitySnapshot(
            token: token,
            app: app,
            text: elements.compactMap { [$0.title, $0.value].compactMap { $0 }.joined(separator: " ") }.filter { !$0.isEmpty }.joined(separator: "\n"),
            elements: elements
        )
    }

    public func element(snapshotToken: UUID, index: Int) throws -> SnapshotElement {
        guard let snapshot = snapshotsByProcess.values.first(where: { $0.token == snapshotToken }) else {
            throw ServiceError(code: .staleSnapshot, message: "Snapshot expired")
        }
        guard snapshot.elements.indices.contains(index) else {
            throw ServiceError(code: .elementNotFound, message: "Element not found")
        }
        return snapshot.elements[index]
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

public final class SystemAXProvider: AXProviding {
    private var elementsByReference: [AXElementReference: AXUIElement] = [:]
    private var referencesByProcess: [Int32: Set<AXElementReference>] = [:]

    public init() {}

    public func rootElement(for app: ApplicationDescriptor) throws -> AXElementReference {
        clearReferences(for: app.processIdentifier)
        return store(AXUIElementCreateApplication(pid_t(app.processIdentifier)), for: app.processIdentifier)
    }

    public func attributes(for element: AXElementReference) throws -> AXElementAttributes {
        let axElement = try resolve(element)
        return AXElementAttributes(
            role: stringAttribute(kAXRoleAttribute, for: axElement),
            title: stringAttribute(kAXTitleAttribute, for: axElement),
            value: stringAttribute(kAXValueAttribute, for: axElement),
            frame: frameAttribute(for: axElement),
            actions: try actionNames(for: axElement)
        )
    }

    public func children(of element: AXElementReference) throws -> [AXElementReference] {
        let axElement = try resolve(element)
        let processIdentifier = try processIdentifier(for: element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else {
            return []
        }
        return children.map { store($0, for: processIdentifier) }
    }

    private func stringAttribute(_ attribute: String, for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func frameAttribute(for element: AXUIElement) -> SnapshotFrame? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success,
              let value else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return SnapshotFrame(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    private func actionNames(for element: AXUIElement) throws -> [String] {
        var actions: CFArray?
        let error = AXUIElementCopyActionNames(element, &actions)
        guard error == .success else { return [] }
        return actions as? [String] ?? []
    }

    private func resolve(_ reference: AXElementReference) throws -> AXUIElement {
        guard let element = elementsByReference[reference] else {
            throw ServiceError(code: .staleSnapshot, message: "Snapshot expired")
        }
        return element
    }

    private func processIdentifier(for reference: AXElementReference) throws -> Int32 {
        guard let processIdentifier = referencesByProcess.first(where: { $0.value.contains(reference) })?.key else {
            throw ServiceError(code: .staleSnapshot, message: "Snapshot expired")
        }
        return processIdentifier
    }

    private func store(_ element: AXUIElement, for processIdentifier: Int32) -> AXElementReference {
        for reference in referencesByProcess[processIdentifier] ?? [] {
            if let existing = elementsByReference[reference], CFEqual(existing, element) {
                return reference
            }
        }
        let reference = AXElementReference(identifier: UUID().uuidString)
        elementsByReference[reference] = element
        referencesByProcess[processIdentifier, default: []].insert(reference)
        return reference
    }

    private func clearReferences(for processIdentifier: Int32) {
        for reference in referencesByProcess.removeValue(forKey: processIdentifier) ?? [] {
            elementsByReference.removeValue(forKey: reference)
        }
    }
}
