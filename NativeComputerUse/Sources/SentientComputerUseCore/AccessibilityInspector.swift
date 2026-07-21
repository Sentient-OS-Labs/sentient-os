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
    func children(of element: AXElementReference, limit: Int) throws -> [AXElementReference]
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

struct SnapshotElementReference: Sendable, Equatable {
    let axReference: AXElementReference
}

/// Keeps AX references out of all service wire types while allowing semantic input.
protocol SnapshotElementReferenceResolving {
    func resolveElementReference(snapshotToken: UUID, index: Int) throws -> SnapshotElementReference
    func resolveLatestElementReference(app: ApplicationDescriptor, index: Int) throws -> SnapshotElementReference
    func latestElement(app: ApplicationDescriptor, index: Int) throws -> SnapshotElement
}

public final class AccessibilityInspector: AccessibilityInspecting, SnapshotElementReferenceResolving {
    public static let defaultMaxDepth = 12
    public static let defaultMaxElements = 500
    public static let maximumAttributeUTF8Bytes = 4 * 1024
    public static let maximumSnapshotUTF8Bytes = 512 * 1024

    private static let attributeTruncationMarker = "…[truncated]"
    private static let snapshotTruncationMarker = "…[snapshot truncated]"

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
                role: Self.boundedNormalized(attributes.role),
                title: Self.boundedNormalized(attributes.title),
                value: Self.boundedNormalized(attributes.value),
                frame: attributes.frame,
                actions: attributes.actions.compactMap(Self.boundedNormalized)
            )
            elements.append(element)
            references.append(item.element)

            let pendingElements = queue.count - cursor
            let remainingChildBudget = elementLimit - elements.count - pendingElements
            if item.depth < depthLimit, remainingChildBudget > 0 {
                let children = try provider.children(of: item.element, limit: remainingChildBudget)
                queue.append(contentsOf: children.map { ($0, item.depth + 1) })
            }
        }

        let token = UUID()
        let bounded = Self.boundedSnapshot(
            token: token,
            app: app,
            elements: elements,
            references: references
        )
        snapshotsByProcess[app.processIdentifier] = CachedSnapshot(
            token: token,
            elements: bounded.snapshot.elements,
            references: bounded.references
        )
        return bounded.snapshot
    }

    public func element(snapshotToken: UUID, index: Int) throws -> SnapshotElement {
        try cachedSnapshot(for: snapshotToken, index: index).elements[index]
    }

    func resolveElementReference(snapshotToken: UUID, index: Int) throws -> SnapshotElementReference {
        let snapshot = try cachedSnapshot(for: snapshotToken, index: index)
        return SnapshotElementReference(axReference: snapshot.references[index])
    }

    func resolveLatestElementReference(app: ApplicationDescriptor, index: Int) throws -> SnapshotElementReference {
        let snapshot = try latestSnapshot(for: app, index: index)
        return SnapshotElementReference(axReference: snapshot.references[index])
    }

    func latestElement(app: ApplicationDescriptor, index: Int) throws -> SnapshotElement {
        try latestSnapshot(for: app, index: index).elements[index]
    }

    private func cachedSnapshot(for token: UUID, index: Int) throws -> CachedSnapshot {
        guard let snapshot = snapshotsByProcess.values.first(where: { $0.token == token }) else {
            throw ServiceError(code: .staleSnapshot, message: "Snapshot expired")
        }
        return try validate(snapshot: snapshot, index: index)
    }

    private func latestSnapshot(for app: ApplicationDescriptor, index: Int) throws -> CachedSnapshot {
        guard let snapshot = snapshotsByProcess[app.processIdentifier] else {
            throw ServiceError(code: .staleSnapshot, message: "Snapshot expired")
        }
        return try validate(snapshot: snapshot, index: index)
    }

    private func validate(snapshot: CachedSnapshot, index: Int) throws -> CachedSnapshot {
        guard snapshot.elements.indices.contains(index) else {
            throw ServiceError(code: .elementNotFound, message: "Element not found")
        }
        return snapshot
    }

    private static func boundedNormalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let markerBytes = attributeTruncationMarker.utf8.count
        let contentLimit = max(0, maximumAttributeUTF8Bytes - markerBytes)
        let inputWorkLimit = maximumAttributeUTF8Bytes * 2
        var output = [UInt8]()
        output.reserveCapacity(contentLimit)
        var inspectedBytes = 0
        var pendingSpace = false
        var truncated = false

        for scalar in value.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard inspectedBytes + scalarBytes <= inputWorkLimit else {
                truncated = true
                break
            }
            inspectedBytes += scalarBytes

            if scalar.properties.isWhitespace {
                pendingSpace = !output.isEmpty
                continue
            }

            let separatorBytes = pendingSpace ? 1 : 0
            guard output.count + separatorBytes + scalarBytes <= contentLimit else {
                truncated = true
                break
            }
            if pendingSpace {
                output.append(0x20)
                pendingSpace = false
            }
            output.append(contentsOf: String(scalar).utf8)
        }

        guard !output.isEmpty else { return nil }
        let result = String(decoding: output, as: UTF8.self)
        return truncated ? result + attributeTruncationMarker : result
    }

    private static func boundedSnapshot(
        token: UUID,
        app: ApplicationDescriptor,
        elements: [SnapshotElement],
        references: [AXElementReference]
    ) -> (snapshot: AccessibilitySnapshot, references: [AXElementReference]) {
        let full = makeSnapshot(token: token, app: app, elements: elements, truncated: false)
        if encodedSize(of: full) <= maximumSnapshotUTF8Bytes {
            return (full, references)
        }

        var lowerBound = 0
        var upperBound = elements.count
        while lowerBound < upperBound {
            let candidate = (lowerBound + upperBound + 1) / 2
            let snapshot = makeSnapshot(
                token: token,
                app: app,
                elements: Array(elements.prefix(candidate)),
                truncated: true
            )
            if encodedSize(of: snapshot) <= maximumSnapshotUTF8Bytes {
                lowerBound = candidate
            } else {
                upperBound = candidate - 1
            }
        }

        let keptElements = Array(elements.prefix(lowerBound))
        return (
            makeSnapshot(token: token, app: app, elements: keptElements, truncated: true),
            Array(references.prefix(lowerBound))
        )
    }

    private static func makeSnapshot(
        token: UUID,
        app: ApplicationDescriptor,
        elements: [SnapshotElement],
        truncated: Bool
    ) -> AccessibilitySnapshot {
        var text = elements.compactMap {
            [$0.title, $0.value].compactMap { $0 }.joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: "\n")
        if truncated {
            if !text.isEmpty { text.append("\n") }
            text.append(snapshotTruncationMarker)
        }
        return AccessibilitySnapshot(token: token, app: app, text: text, elements: elements)
    }

    private static func encodedSize(of snapshot: AccessibilitySnapshot) -> Int {
        (try? JSONEncoder().encode(snapshot).count) ?? .max
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

    public func children(of element: AXElementReference, limit: Int) throws -> [AXElementReference] {
        guard limit > 0 else { return [] }
        let axElement = try resolve(element)
        let processIdentifier = try processIdentifier(for: element)
        var availableCount = 0
        guard AXUIElementGetAttributeValueCount(
            axElement,
            kAXChildrenAttribute as CFString,
            &availableCount
        ) == .success else {
            return []
        }
        var values: CFArray?
        let requestedCount = min(availableCount, limit)
        guard requestedCount > 0,
              AXUIElementCopyAttributeValues(
                axElement,
                kAXChildrenAttribute as CFString,
                0,
                requestedCount,
                &values
              ) == .success,
              let children = values as? [AXUIElement] else { return [] }
        return children.map { store($0, for: processIdentifier) }
    }

    private func stringAttribute(_ attribute: String, for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func frameAttribute(for element: AXUIElement) -> SnapshotFrame? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success else {
            return nil
        }
        return Self.frame(from: value)
    }

    static func frame(from value: CFTypeRef?) -> SnapshotFrame? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
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

    func resolve(_ reference: AXElementReference) throws -> AXUIElement {
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
