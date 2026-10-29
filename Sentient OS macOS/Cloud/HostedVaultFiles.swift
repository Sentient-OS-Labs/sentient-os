// File capability for hosted knowledge generation. Every operation stays beneath one open
// staging-directory descriptor; no shell, absolute path, symlink or app-managed note access.
import Darwin
import Foundation

nonisolated final class HostedVaultFiles {
    enum Failure: String, Error { case invalidArguments, unavailable, tooLarge, budgetExceeded, ambiguousEdit }
    static let maximumFileBytes = 256 * 1_024
    static let maximumTransferBytes = 8 * 1_024 * 1_024
    private let root: Int32
    private var transferred = 0

    init(root url: URL) throws {
        guard url.isFileURL,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { throw Failure.unavailable }
        root = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Failure.unavailable }
    }
    deinit { close(root) }

    func call(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
        try Task.checkCancellation()
        guard transferred <= Self.maximumTransferBytes else { throw Failure.budgetExceeded }
        switch name {
        case "vault_list":
            guard arguments.isEmpty else { throw Failure.invalidArguments }
            return try list()
        case "vault_read":
            guard Set(arguments.keys) == ["path"], let path = arguments["path"] as? String else { throw Failure.invalidArguments }
            let text = try read(path)
            try charge(text.utf8.count)
            return ["path": path, "text": text]
        case "vault_write":
            guard Set(arguments.keys) == ["path", "text"], let path = arguments["path"] as? String,
                  let text = arguments["text"] as? String else { throw Failure.invalidArguments }
            try write(path, text: text)
            return ["path": path, "bytes_written": text.utf8.count]
        case "vault_edit":
            guard Set(arguments.keys) == ["path", "old_text", "new_text"], let path = arguments["path"] as? String,
                  let old = arguments["old_text"] as? String, let new = arguments["new_text"] as? String,
                  !old.isEmpty, old.utf8.count <= Self.maximumFileBytes, new.utf8.count <= Self.maximumFileBytes else { throw Failure.invalidArguments }
            let original = try read(path)
            guard let match = original.range(of: old), original[match.upperBound...].range(of: old) == nil else { throw Failure.ambiguousEdit }
            let updated = original.replacingCharacters(in: match, with: new)
            try write(path, text: updated)
            return ["path": path, "bytes_written": updated.utf8.count]
        default: throw Failure.invalidArguments
        }
    }

    private func charge(_ bytes: Int) throws {
        guard bytes >= 0, transferred + bytes <= Self.maximumTransferBytes else { throw Failure.budgetExceeded }
        transferred += bytes
    }
    private static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, path.utf8.count <= 1_024, parts.count <= 16,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.contains("\\"), parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && $0.utf8.count <= 255 }),
              let file = parts.last, file.lowercased().hasSuffix(".md"), file.lowercased() != "writingstyle.md" else { throw Failure.invalidArguments }
        return parts
    }
    private func parent(_ path: String, create: Bool) throws -> (Int32, String) {
        let parts = try Self.components(path)
        var directory = dup(root)
        guard directory >= 0 else { throw Failure.unavailable }
        do {
            for component in parts.dropLast() {
                var next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, create, errno == ENOENT {
                    guard mkdirat(directory, component, 0o700) == 0 || errno == EEXIST else { throw Failure.unavailable }
                    next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw Failure.unavailable }
                close(directory); directory = next
            }
            return (directory, parts.last!)
        } catch { close(directory); throw error }
    }
    private func read(_ path: String) throws -> String {
        let (directory, file) = try parent(path, create: false)
        defer { close(directory) }
        let descriptor = openat(directory, file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= Self.maximumFileBytes else { throw Failure.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes, let text = String(data: data, encoding: .utf8) else { throw Failure.tooLarge }
        return text
    }
    private func write(_ path: String, text: String) throws {
        let data = Data(text.utf8)
        guard data.count <= Self.maximumFileBytes else { throw Failure.tooLarge }
        try charge(data.count)
        let (directory, file) = try parent(path, create: true)
        defer { close(directory) }
        var info = stat()
        if fstatat(directory, file, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw Failure.unavailable }
        } else if errno != ENOENT { throw Failure.unavailable }
        let temporary = ".sentient-write-" + UUID().uuidString
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try Task.checkCancellation()
        guard renameat(directory, temporary, directory, file) == 0 else { throw Failure.unavailable }
    }
    private func list() throws -> [String: Any] {
        var paths: [String] = [], visited = 0, complete = true
        func walk(_ descriptor: Int32, prefix: String, depth: Int) throws {
            guard depth < 16, visited < 5_000, paths.count < 1_000 else { complete = false; return }
            let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard copy >= 0 else { throw Failure.unavailable }
            guard let stream = fdopendir(copy) else { close(copy); throw Failure.unavailable }
            defer { closedir(stream) }
            while let entry = readdir(stream) {
                try Task.checkCancellation()
                guard visited < 5_000, paths.count < 1_000 else { complete = false; return }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                guard !name.hasPrefix(".") else { continue }
                visited += 1
                var info = stat()
                guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { complete = false; continue }
                let path = prefix + name
                if (info.st_mode & S_IFMT) == S_IFDIR {
                    let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { complete = false; continue }
                    defer { close(child) }
                    try walk(child, prefix: path + "/", depth: depth + 1)
                } else if (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
                          (try? Self.components(path)) != nil { paths.append(path) }
            }
        }
        try walk(root, prefix: "", depth: 0)
        try charge(paths.reduce(0) { $0 + $1.utf8.count })
        return ["paths": paths.sorted(), "complete": complete]
    }
}
