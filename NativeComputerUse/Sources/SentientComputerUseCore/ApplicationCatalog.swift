import AppKit
import Foundation

public struct ApplicationDescriptor: Codable, Sendable, Equatable {
    public let name: String
    public let bundleIdentifier: String?
    public let path: String
    public let processIdentifier: Int32

    public init(name: String, bundleIdentifier: String?, path: String, processIdentifier: Int32) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.processIdentifier = processIdentifier
    }
}

public struct WorkspaceApplication: Sendable, Equatable {
    public let name: String
    public let bundleIdentifier: String?
    public let path: String
    public let processIdentifier: Int32
    public let isBackgroundOnly: Bool

    public init(
        name: String,
        bundleIdentifier: String?,
        path: String,
        processIdentifier: Int32,
        isBackgroundOnly: Bool
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.processIdentifier = processIdentifier
        self.isBackgroundOnly = isBackgroundOnly
    }

    fileprivate var descriptor: ApplicationDescriptor {
        ApplicationDescriptor(
            name: name,
            bundleIdentifier: bundleIdentifier,
            path: path,
            processIdentifier: processIdentifier
        )
    }
}

public protocol WorkspaceProviding {
    func runningApplications() -> [WorkspaceApplication]
}

protocol ApplicationCataloging {
    func applications() -> [ApplicationDescriptor]
    func resolve(_ query: String) throws -> ApplicationDescriptor
}

protocol ApplicationActivating {
    func activateAndVerifyFrontmost(_ app: ApplicationDescriptor) -> Bool
}

protocol ApplicationLaunchRequesting {
    func activate(_ application: ApplicationDescriptor) -> Bool
}

protocol FrontmostApplicationProviding {
    func frontmostProcessIdentifier() -> Int32?
}

struct LaunchServicesApplicationLauncher: ApplicationLaunchRequesting {
    func activate(_ application: ApplicationDescriptor) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty {
            process.arguments = ["-b", bundleIdentifier]
        } else {
            process.arguments = ["-a", application.name]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

struct SystemFrontmostApplicationProvider: FrontmostApplicationProviding {
    func frontmostProcessIdentifier() -> Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

struct SystemApplicationActivator: ApplicationActivating {
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let launcher: any ApplicationLaunchRequesting
    private let frontmostProvider: any FrontmostApplicationProviding

    init(
        timeout: TimeInterval = 1,
        pollInterval: TimeInterval = 0.02,
        launcher: any ApplicationLaunchRequesting = LaunchServicesApplicationLauncher(),
        frontmostProvider: any FrontmostApplicationProviding = SystemFrontmostApplicationProvider()
    ) {
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.launcher = launcher
        self.frontmostProvider = frontmostProvider
    }

    func activateAndVerifyFrontmost(_ app: ApplicationDescriptor) -> Bool {
        guard launcher.activate(app) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if frontmostProvider.frontmostProcessIdentifier() == app.processIdentifier {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return false
    }
}

public struct SystemWorkspaceProvider: WorkspaceProviding {
    public init() {}

    public func runningApplications() -> [WorkspaceApplication] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard let name = application.localizedName,
                  let executableURL = application.executableURL else {
                return nil
            }

            return WorkspaceApplication(
                name: name,
                bundleIdentifier: application.bundleIdentifier,
                path: executableURL.standardizedFileURL.path,
                processIdentifier: application.processIdentifier,
                isBackgroundOnly: application.activationPolicy == .prohibited
            )
        }
    }
}

public final class ApplicationCatalog: ApplicationCataloging {
    private let workspace: any WorkspaceProviding

    public init(workspace: any WorkspaceProviding = SystemWorkspaceProvider()) {
        self.workspace = workspace
    }

    public func applications() -> [ApplicationDescriptor] {
        workspace.runningApplications()
            .filter { !$0.isBackgroundOnly }
            .map(\.descriptor)
    }

    public func resolve(_ query: String) throws -> ApplicationDescriptor {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let applications = workspace.runningApplications().filter { !$0.isBackgroundOnly }

        if let application = applications.first(where: { $0.bundleIdentifier == query }) {
            return application.descriptor
        }

        let canonicalPath = Self.canonicalPath(query)
        if let application = applications.first(where: { Self.canonicalPath($0.path) == canonicalPath }) {
            return application.descriptor
        }

        if let application = applications.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            return application.descriptor
        }

        let prefixMatches = applications.filter { $0.name.range(of: query, options: [.caseInsensitive, .anchored]) != nil }
        if prefixMatches.count == 1, let application = prefixMatches.first {
            return application.descriptor
        }

        throw ServiceError(code: .applicationNotFound, message: "Application not found")
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
