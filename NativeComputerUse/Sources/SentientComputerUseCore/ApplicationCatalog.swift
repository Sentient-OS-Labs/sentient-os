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

public final class ApplicationCatalog {
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
