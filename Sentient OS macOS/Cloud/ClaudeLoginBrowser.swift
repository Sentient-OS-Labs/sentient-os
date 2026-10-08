// Captures Claude's automatic browser URL through a private, per-attempt FIFO.
// The short-lived helper opens the same URL in the default browser; stop() removes its IPC.
// Doc: Documentation - Cloud - ClaudeCLI (the claude -p engine).md

import Foundation
import Darwin

nonisolated final class ClaudeLoginBrowser: @unchecked Sendable {
    static let helperArgument = "--sentient-login-browser"
    static let pipeEnvironmentKey = "SENTIENT_LOGIN_BROWSER_PIPE"
    let environment: [String: String]
    private let source: DispatchSourceRead
    // Only the source's serial queue accesses the decoder. Cancellation is thread-safe.
    private var decoder = LoginLink.Decoder(provider: .claude)

    init(onURL: @escaping @Sendable (URL) -> Void) throws {
        guard let executable = Bundle.main.executablePath else { throw CocoaError(.fileNoSuchFile) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentient-login-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let fifo = directory.appendingPathComponent("browser.pipe")
        let launcher = directory.appendingPathComponent("browser")
        var descriptor: Int32 = -1
        do {
            guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(.EIO) }
            descriptor = open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            let quotedExecutable = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let script = "#!/bin/sh\nexec \(quotedExecutable) \(Self.helperArgument) \"$@\"\n"
            try Data(script.utf8).write(to: launcher)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        } catch {
            if descriptor >= 0 { close(descriptor) }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        environment = ["BROWSER": launcher.path, Self.pipeEnvironmentKey: fifo.path]
        let fd = descriptor
        source = DispatchSource.makeReadSource(fileDescriptor: fd,
            queue: DispatchQueue(label: "sentient.login.browser"))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(fd, &bytes, bytes.count)
                guard count > 0 else { return }
                if let url = self.decoder.append(Data(bytes.prefix(count))) { onURL(url) }
            }
        }
        source.setCancelHandler {
            close(fd)
            try? FileManager.default.removeItem(at: directory)
        }
        source.resume()
    }

    func stop() { source.cancel() }
    deinit { source.cancel() }

    /// Runs before GUI/diagnostics initialization. URL arguments never enter app logging.
    /// A nonblocking write also makes a helper racing cancellation exit instead of hanging.
    static func runHelper(arguments: [String]) -> Int32 {
        guard arguments.count == 3,
              let url = LoginLink.authorizationURL(arguments[2], provider: .claude),
              let path = ProcessInfo.processInfo.environment[pipeEnvironmentKey] else { return 1 }
        let fd = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return 1 }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
              info.st_uid == getuid() else { return 1 }
        signal(SIGPIPE, SIG_IGN)
        let data = Data((url.absoluteString + "\n").utf8)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard written == data.count else { return 1 }

        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = [url.absoluteString]
        opener.standardInput = FileHandle.nullDevice
        opener.standardOutput = FileHandle.nullDevice
        opener.standardError = FileHandle.nullDevice
        do { try opener.run(); opener.waitUntilExit(); return opener.terminationStatus }
        catch { return 1 }
    }
}
