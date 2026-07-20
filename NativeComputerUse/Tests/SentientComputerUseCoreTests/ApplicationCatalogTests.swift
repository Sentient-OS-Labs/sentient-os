import XCTest
@testable import SentientComputerUseCore

final class ApplicationCatalogTests: XCTestCase {
    func testExactBundleIdentifierWinsOverDisplayNameMatch() throws {
        let workspace = FakeWorkspace(applications: [
            .init(name: "Safari", bundleIdentifier: "com.example.Safari", path: "/Applications/Safari.app", processIdentifier: 11, isBackgroundOnly: false),
            .init(name: "com.apple.Safari", bundleIdentifier: "com.apple.Safari", path: "/Applications/Other.app", processIdentifier: 12, isBackgroundOnly: false)
        ])
        let catalog = ApplicationCatalog(workspace: workspace)

        XCTAssertEqual(try catalog.resolve("com.apple.Safari").processIdentifier, 12)
    }

    func testResolveMissingApplicationThrowsApplicationNotFound() {
        let catalog = ApplicationCatalog(workspace: FakeWorkspace(applications: []))

        XCTAssertThrowsError(try catalog.resolve("Missing")) {
            XCTAssertEqual($0 as? ServiceError, ServiceError(code: .applicationNotFound, message: "Application not found"))
        }
    }
}

private struct FakeWorkspace: WorkspaceProviding {
    let applications: [WorkspaceApplication]

    func runningApplications() -> [WorkspaceApplication] {
        applications
    }
}
