import XCTest
@testable import SentientComputerUseCore

final class AccessibilityInspectorTests: XCTestCase {
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
}

private extension ApplicationDescriptor {
    static let fixture = ApplicationDescriptor(
        name: "Fixture",
        bundleIdentifier: "com.example.fixture",
        path: "/Applications/Fixture.app",
        processIdentifier: 123
    )
}
