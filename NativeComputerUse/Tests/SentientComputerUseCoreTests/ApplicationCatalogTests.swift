import XCTest
@testable import SentientComputerUseCore

final class ApplicationCatalogTests: XCTestCase {
    func testSystemActivatorUsesLaunchServicesBeforeCheckingFrontmostApplication() {
        let launcher = RecordingApplicationLauncher()
        let frontmost = FrontmostAfterLaunchProvider(launcher: launcher, processIdentifier: 467)
        let activator = SystemApplicationActivator(
            timeout: 0.1,
            pollInterval: 0.001,
            launcher: launcher,
            frontmostProvider: frontmost
        )
        let chrome = ApplicationDescriptor(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            processIdentifier: 467
        )

        XCTAssertTrue(activator.activateAndVerifyFrontmost(chrome))
        XCTAssertEqual(launcher.activatedApplications, [chrome])
    }

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

private final class RecordingApplicationLauncher: ApplicationLaunchRequesting, @unchecked Sendable {
    private(set) var activatedApplications: [ApplicationDescriptor] = []

    func activate(_ application: ApplicationDescriptor) -> Bool {
        activatedApplications.append(application)
        return true
    }
}

private struct FrontmostAfterLaunchProvider: FrontmostApplicationProviding {
    let launcher: RecordingApplicationLauncher
    let processIdentifier: Int32

    func frontmostProcessIdentifier() -> Int32? {
        launcher.activatedApplications.isEmpty ? nil : processIdentifier
    }
}

private struct FakeWorkspace: WorkspaceProviding {
    let applications: [WorkspaceApplication]

    func runningApplications() -> [WorkspaceApplication] {
        applications
    }
}
