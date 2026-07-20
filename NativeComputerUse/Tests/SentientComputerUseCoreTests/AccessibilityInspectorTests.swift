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

    func children(of element: AXElementReference) throws -> [AXElementReference] {
        childrenByNode[element, default: []]
    }
}

private struct Tree {
    let root: AXElementReference
    let nodes: [AXElementReference: AXElementAttributes]
    let childrenByNode: [AXElementReference: [AXElementReference]]

    static func chain(length: Int) -> Tree {
        let references = (0..<length).map { AXElementReference(identifier: "node-\($0)") }
        let nodes = Dictionary(uniqueKeysWithValues: references.map {
            ($0, AXElementAttributes(role: "AXButton", title: "Node \($0.identifier)", value: nil, frame: nil, actions: ["AXPress"]))
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
