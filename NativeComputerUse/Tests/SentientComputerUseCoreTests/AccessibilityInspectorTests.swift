import ApplicationServices
import XCTest
@testable import SentientComputerUseCore

final class AccessibilityInspectorTests: XCTestCase {
    func testResolveElementReferenceReturnsSnapshotLocalReferenceAndRejectsStaleToken() throws {
        let inspector = AccessibilityInspector(provider: FakeAXProvider(tree: .chain(length: 2)))
        let first = try inspector.snapshot(app: .fixture, maxDepth: 8, maxElements: 5)

        XCTAssertEqual(
            try inspector.resolveElementReference(snapshotToken: first.token, index: 0).axReference,
            AXElementReference(identifier: "node-0")
        )
        XCTAssertThrowsError(try inspector.resolveElementReference(snapshotToken: first.token, index: 2)) {
            XCTAssertEqual($0 as? ServiceError, ServiceError(code: .elementNotFound, message: "Element not found"))
        }

        _ = try inspector.snapshot(app: .fixture, maxDepth: 8, maxElements: 5)
        XCTAssertThrowsError(try inspector.resolveElementReference(snapshotToken: first.token, index: 0)) {
            XCTAssertEqual($0 as? ServiceError, ServiceError(code: .staleSnapshot, message: "Snapshot expired"))
        }
    }

    func testSnapshotIsBoundedAndIndexesAreSnapshotLocal() throws {
        let ax = FakeAXProvider(tree: .chain(length: 20))
        let inspector = AccessibilityInspector(provider: ax)
        let first = try inspector.snapshot(app: .fixture, maxDepth: 8, maxElements: 5)
        XCTAssertEqual(first.elements.count, 5)
        let second = try inspector.snapshot(app: .fixture, maxDepth: 8, maxElements: 5)

        XCTAssertThrowsError(try inspector.element(snapshotToken: first.token, index: 0)) {
            XCTAssertEqual($0 as? ServiceError, ServiceError(code: .staleSnapshot, message: "Snapshot expired"))
        }
        XCTAssertNoThrow(try inspector.element(snapshotToken: second.token, index: 0))
    }

    func testSnapshotTraversalIsBreadthFirstAndDeduplicatesReferences() throws {
        let inspector = AccessibilityInspector(provider: FakeAXProvider(tree: .branchWithRepeatedLeaf))

        let snapshot = try inspector.snapshot(app: .fixture, maxDepth: 3, maxElements: 10)

        XCTAssertEqual(snapshot.elements.map(\.title), ["Root", "Left", "Right", "Shared"])
    }

    func testFrameConversionIgnoresValueThatIsNotAXValue() {
        let nonFrame: CFTypeRef = "not an AXValue" as CFString

        XCTAssertNil(SystemAXProvider.frame(from: nonFrame))
    }

    func testSnapshotCapsEveryAXStringAttributeByUTF8BytesWithVisibleMarker() throws {
        let oversized = String(repeating: "é", count: 4_000)
        let inspector = AccessibilityInspector(provider: FakeAXProvider(
            tree: .chain(length: 1, attributeText: oversized)
        ))

        let snapshot = try inspector.snapshot(app: .fixture, maxDepth: 1, maxElements: 1)
        let element = try XCTUnwrap(snapshot.elements.first)
        let strings = [element.role, element.title, element.value] + element.actions.map(Optional.some)

        for string in strings.compactMap({ $0 }) {
            XCTAssertLessThanOrEqual(string.utf8.count, 4_096)
            XCTAssertTrue(string.hasSuffix("…[truncated]"))
        }
    }

    func testSnapshotCapsTotalEncodedUTF8OutputWithVisibleMarker() throws {
        let oversized = String(repeating: "x", count: 20_000)
        let inspector = AccessibilityInspector(provider: FakeAXProvider(
            tree: .chain(length: 100, attributeText: oversized)
        ))

        let snapshot = try inspector.snapshot(app: .fixture, maxDepth: 100, maxElements: 100)
        let encoded = try JSONEncoder().encode(snapshot)

        XCTAssertLessThanOrEqual(encoded.count, 512 * 1_024)
        XCTAssertTrue(snapshot.text.hasSuffix("…[snapshot truncated]"))
    }

    func testSnapshotRequestsOnlyTheRemainingChildBudget() throws {
        let provider = VirtualWideAXProvider(availableChildren: 1_000_000)
        let inspector = AccessibilityInspector(provider: provider)

        let snapshot = try inspector.snapshot(app: .fixture, maxDepth: 1, maxElements: 500)

        XCTAssertEqual(snapshot.elements.count, 500)
        XCTAssertEqual(provider.requestedLimits, [499])
        XCTAssertEqual(provider.generatedChildren, 499)
    }

    func testAttributeNormalizationStopsAfterBoundedInputWork() throws {
        let oversizedLeadingWhitespace = String(repeating: " \n", count: 100_000) + "unreachable"
        let provider = FakeAXProvider(tree: .chain(length: 1, attributeText: oversizedLeadingWhitespace))
        let inspector = AccessibilityInspector(provider: provider)

        let snapshot = try inspector.snapshot(app: .fixture, maxDepth: 0, maxElements: 1)

        XCTAssertNil(snapshot.elements[0].title)
    }

    func testSingleHugeExtendedGraphemeIsBoundedByUnicodeScalarWork() throws {
        let combiningMark = "\u{0301}"
        let oversizedGrapheme = "a" + String(repeating: combiningMark, count: 100_000)
        let inspector = AccessibilityInspector(provider: FakeAXProvider(
            tree: .chain(length: 1, attributeText: oversizedGrapheme)
        ))

        let snapshot = try inspector.snapshot(app: .fixture, maxDepth: 0, maxElements: 1)
        let title = try XCTUnwrap(snapshot.elements[0].title)

        XCTAssertEqual(title.unicodeScalars.first, "a".unicodeScalars.first)
        XCTAssertTrue(title.hasSuffix("…[truncated]"))
        XCTAssertLessThanOrEqual(title.utf8.count, AccessibilityInspector.maximumAttributeUTF8Bytes)
        XCTAssertLessThan(
            title.unicodeScalars.count,
            oversizedGrapheme.unicodeScalars.count / 10,
            "normalization must stop after its bounded scalar/byte prefix"
        )
    }
}

private final class FakeAXProvider: AXProviding {
    private let nodes: [AXElementReference: AXElementAttributes]
    private let childrenByNode: [AXElementReference: [AXElementReference]]
    private let root: AXElementReference

    init(tree: Tree) {
        root = tree.root
        nodes = tree.nodes
        childrenByNode = tree.childrenByNode
    }

    func rootElement(for app: ApplicationDescriptor) throws -> AXElementReference {
        root
    }

    func attributes(for element: AXElementReference) throws -> AXElementAttributes {
        nodes[element]!
    }

    func children(of element: AXElementReference, limit: Int) throws -> [AXElementReference] {
        Array(childrenByNode[element, default: []].prefix(limit))
    }
}

private final class VirtualWideAXProvider: AXProviding {
    private let root = AXElementReference(identifier: "root")
    private let availableChildren: Int
    private(set) var requestedLimits: [Int] = []
    private(set) var generatedChildren = 0

    init(availableChildren: Int) {
        self.availableChildren = availableChildren
    }

    func rootElement(for app: ApplicationDescriptor) throws -> AXElementReference {
        root
    }

    func attributes(for element: AXElementReference) throws -> AXElementAttributes {
        AXElementAttributes(role: "AXButton", title: element.identifier, value: nil, frame: nil, actions: [])
    }

    func children(of element: AXElementReference, limit: Int) throws -> [AXElementReference] {
        requestedLimits.append(limit)
        guard element == root else { return [] }
        let count = min(availableChildren, max(0, limit))
        generatedChildren += count
        return (0..<count).map { AXElementReference(identifier: "child-\($0)") }
    }
}

private struct Tree {
    let root: AXElementReference
    let nodes: [AXElementReference: AXElementAttributes]
    let childrenByNode: [AXElementReference: [AXElementReference]]

    static func chain(length: Int, attributeText: String? = nil) -> Tree {
        let references = (0..<length).map { AXElementReference(identifier: "node-\($0)") }
        let nodes = Dictionary(uniqueKeysWithValues: references.map {
            ($0, AXElementAttributes(
                role: attributeText ?? "AXButton",
                title: attributeText ?? "Node \($0.identifier)",
                value: attributeText,
                frame: nil,
                actions: [attributeText ?? "AXPress"]
            ))
        })
        let children = Dictionary(uniqueKeysWithValues: zip(references, references.dropFirst()).map { ($0, [$1]) })
        return Tree(root: references[0], nodes: nodes, childrenByNode: children)
    }

    static let branchWithRepeatedLeaf: Tree = {
        let root = AXElementReference(identifier: "root")
        let left = AXElementReference(identifier: "left")
        let right = AXElementReference(identifier: "right")
        let shared = AXElementReference(identifier: "shared")
        let nodes = [
            root: AXElementAttributes(role: "AXGroup", title: "Root", value: nil, frame: nil, actions: []),
            left: AXElementAttributes(role: "AXButton", title: "Left", value: nil, frame: nil, actions: []),
            right: AXElementAttributes(role: "AXButton", title: "Right", value: nil, frame: nil, actions: []),
            shared: AXElementAttributes(role: "AXButton", title: "Shared", value: nil, frame: nil, actions: [])
        ]
        return Tree(root: root, nodes: nodes, childrenByNode: [
            root: [left, right],
            left: [shared],
            right: [shared]
        ])
    }()
}

private extension ApplicationDescriptor {
    static let fixture = ApplicationDescriptor(
        name: "Fixture",
        bundleIdentifier: "com.example.fixture",
        path: "/Applications/Fixture.app",
        processIdentifier: 123
    )
}
