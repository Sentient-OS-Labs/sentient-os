// Read-only validation of model-authored staging before the live knowledge base is replaced.
// The caller must stop the writer and remove its corpus snapshot before invoking this check.

import Foundation
import CryptoKit
import Darwin

nonisolated enum VaultValidation {
    struct Limits: Sendable {
        var maximumFileBytes = 2 * 1_024 * 1_024
        var maximumTotalBytes = 64 * 1_024 * 1_024
        var maximumFiles = 2_000
        var maximumDirectories = 512
        var maximumDepth = 16
        /// A result below one fifth of a substantial prior vault needs human review.
        var minimumRetainedFraction = 0.20
        var shrinkCheckMinimumFiles = 10
        var shrinkCheckMinimumBytes = 10_000
        var importantPaths: Set<String> = ["README.md", "writingstyle.md"]
    }

    struct Summary: Sendable {
        let files: Int
        let bytes: Int
        /// Content-based, independent of mtimes and enumeration order. Includes relative paths.
        let fingerprint: String
        let paths: Set<String>
        fileprivate let markdownBytes: Int
        fileprivate let metadataHashes: [String: String]
    }

    enum Failure: String, Error, LocalizedError, Sendable {
        case invalidRoot, overlappingRoots, outsideRoot, symbolicLink, nonRegularFile, hardLink
        case unexpectedFile, unreadable, fileTooLarge, treeTooLarge, tooManyFiles
        case tooManyDirectories, tooDeep, invalidMarkdown, missingIndex, emptyIndex
        case missingImportantFile, catastrophicShrink, changedDuringValidation, invalidLimits

        var errorDescription: String? {
            // No private filenames or source text appear in UI or diagnostic errors.
            switch self {
            case .catastrophicShrink, .missingImportantFile:
                return "The new knowledge base removed too much existing knowledge. Your original knowledge base was kept."
            case .fileTooLarge, .treeTooLarge, .tooManyFiles, .tooManyDirectories, .tooDeep:
                return "The new knowledge base exceeded the safe size limit. Your original knowledge base was kept."
            case .missingIndex, .emptyIndex:
                return "The new knowledge base is missing its overview. Your original knowledge base was kept."
            default:
                return "The new knowledge base could not be safely validated. Your original knowledge base was kept."
            }
        }
    }

    /// Validates without repairing, deleting, moving, or writing either tree. Existing app-managed
    /// writingstyle.md must already have been preserved into staging by the caller.
    @discardableResult
    static func validate(staging: URL, replacing previous: URL? = nil,
                         limits: Limits = Limits()) throws -> Summary {
        try validateLimits(limits)
        let root = try canonicalDirectory(staging)
        let previousRoot: URL?
        if let previous {
            var metadata = stat()
            let result = previous.path.withCString { lstat($0, &metadata) }
            if result == 0 { previousRoot = try canonicalDirectory(previous) }
            else if errno == ENOENT { previousRoot = nil }
            else { throw Failure.unreadable }
        } else { previousRoot = nil }
        if let previousRoot,
           root == previousRoot || isWithin(root, parent: previousRoot) || isWithin(previousRoot, parent: root) {
            throw Failure.overlappingRoots
        }
        // Existing regular metadata (Finder/Obsidian, for example) may survive unchanged. New or
        // altered non-Markdown output is rejected. Both trees remain subject to the same bounds.
        let original = try previousRoot.map { try scan($0, limits: limits, allowedMetadata: nil) }
        let staged = try scan(root, limits: limits, allowedMetadata: original?.metadataHashes ?? [:])
        guard staged.paths.contains("README.md") else { throw Failure.missingIndex }
        let index = try readRegularFile(root.appendingPathComponent("README.md"), root: root,
                                        maximumBytes: limits.maximumFileBytes)
        guard let text = String(data: index, encoding: .utf8) else { throw Failure.invalidMarkdown }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptyIndex }

        if let original {
            guard Set(original.metadataHashes.keys).isSubset(of: Set(staged.metadataHashes.keys)) else {
                throw Failure.missingImportantFile
            }
            for path in limits.importantPaths where original.paths.contains(path) {
                guard staged.paths.contains(path) else { throw Failure.missingImportantFile }
            }
            let filesShrank = original.files >= limits.shrinkCheckMinimumFiles &&
                Double(staged.files) < Double(original.files) * limits.minimumRetainedFraction
            let bytesShrank = original.markdownBytes >= limits.shrinkCheckMinimumBytes &&
                Double(staged.markdownBytes) < Double(original.markdownBytes) * limits.minimumRetainedFraction
            guard !filesShrank && !bytesShrank else { throw Failure.catastrophicShrink }
        }
        return staged
    }

    /// A bounded live-tree read produces a Markdown content fingerprint for merge checkpoints.
    /// Regular metadata is bounded and verified safe, but never contributes to the knowledge hash.
    /// Unsafe/unreadable trees throw instead of fingerprinting a partial view.
    static func fingerprint(_ root: URL, limits: Limits = Limits()) throws -> String {
        try validateLimits(limits)
        return try scan(canonicalDirectory(root), limits: limits, allowedMetadata: nil).fingerprint
    }

    private static func validateLimits(_ limits: Limits) throws {
        guard limits.maximumFileBytes > 0, limits.maximumTotalBytes > 0,
              limits.maximumFiles > 0, limits.maximumDirectories > 0, limits.maximumDepth > 0,
              limits.shrinkCheckMinimumFiles > 0, limits.shrinkCheckMinimumBytes > 0,
              limits.minimumRetainedFraction.isFinite,
              (0...1).contains(limits.minimumRetainedFraction),
              limits.importantPaths.allSatisfy({ path in
                  !path.isEmpty && !path.hasPrefix("/") &&
                  !path.split(separator: "/", omittingEmptySubsequences: false)
                    .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
              }) else { throw Failure.invalidLimits }
    }

    private static func canonicalDirectory(_ supplied: URL) throws -> URL {
        guard supplied.isFileURL else { throw Failure.invalidRoot }
        // Reject a symlink at the root itself; ordinary system ancestor aliases such as /tmp are OK.
        let metadata = try statWithoutFollowing(supplied)
        guard fileType(metadata) != S_IFLNK else { throw Failure.symbolicLink }
        guard fileType(metadata) == S_IFDIR else { throw Failure.invalidRoot }
        return supplied.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isWithin(_ url: URL, parent: URL) -> Bool {
        let prefix = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return url.path.hasPrefix(prefix)
    }

    private static func statWithoutFollowing(_ url: URL) throws -> stat {
        var metadata = stat()
        guard url.path.withCString({ lstat($0, &metadata) }) == 0 else { throw Failure.unreadable }
        return metadata
    }

    private static func fileType(_ metadata: stat) -> mode_t { metadata.st_mode & S_IFMT }

    /// nil permits bounded original metadata; a non-nil map admits only identical prior files.
    private static func scan(_ root: URL, limits: Limits, allowedMetadata: [String: String]?) throws -> Summary {
        var pending: [(URL, Int)] = [(root, 0)]
        var directoryCount = 0
        var byteCount = 0
        var markdownBytes = 0
        var fileCount = 0
        var metadataHashes: [String: String] = [:]
        var records: [(path: String, hash: String)] = []
        while let (directory, depth) = pending.popLast() {
            let metadata = try statWithoutFollowing(directory)
            guard fileType(metadata) != S_IFLNK else { throw Failure.symbolicLink }
            guard fileType(metadata) == S_IFDIR else { throw Failure.changedDuringValidation }
            guard directory.resolvingSymlinksInPath() == directory else { throw Failure.outsideRoot }
            let children: [URL]
            do { children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
            catch { throw Failure.unreadable }
            for child in children {
                // Inspect the literal directory entry first: Foundation may resolve a dangling
                // symlink while standardizing its URL, which would hide its original file type.
                let entry = try statWithoutFollowing(child)
                guard fileType(entry) != S_IFLNK else { throw Failure.symbolicLink }
                let url = child.standardizedFileURL
                guard isWithin(url, parent: root) else { throw Failure.outsideRoot }
                guard url.resolvingSymlinksInPath() == url else { throw Failure.outsideRoot }
                switch fileType(entry) {
                case S_IFDIR:
                    directoryCount += 1
                    guard directoryCount <= limits.maximumDirectories else { throw Failure.tooManyDirectories }
                    guard depth + 1 <= limits.maximumDepth else { throw Failure.tooDeep }
                    pending.append((url, depth + 1))
                case S_IFREG:
                    // A hard link could share an inode with a file outside the staging tree.
                    guard entry.st_nlink == 1 else { throw Failure.hardLink }
                    guard fileCount < limits.maximumFiles else { throw Failure.tooManyFiles }
                    fileCount += 1
                    guard entry.st_size >= 0, entry.st_size <= limits.maximumFileBytes else { throw Failure.fileTooLarge }
                    guard entry.st_size <= limits.maximumTotalBytes - byteCount else { throw Failure.treeTooLarge }
                    let data = try readRegularFile(url, root: root, maximumBytes: limits.maximumFileBytes)
                    guard data.count <= limits.maximumTotalBytes - byteCount else { throw Failure.treeTooLarge }
                    byteCount += data.count
                    let path = String(url.path.dropFirst(root.path.count + (root.path.hasSuffix("/") ? 0 : 1)))
                    let hash = hex(SHA256.hash(data: data))
                    if url.pathExtension != "md" {
                        if let allowedMetadata, allowedMetadata[path] != hash { throw Failure.unexpectedFile }
                        metadataHashes[path] = hash
                        continue
                    }
                    guard String(data: data, encoding: .utf8) != nil, !data.contains(0) else { throw Failure.invalidMarkdown }
                    markdownBytes += data.count
                    records.append((path, hash))
                default: throw Failure.nonRegularFile
                }
            }
            let after = try statWithoutFollowing(directory)
            guard sameIdentity(metadata, after), sameModification(metadata, after) else { throw Failure.changedDuringValidation }
        }
        var digest = SHA256()
        for record in records.sorted(by: { $0.path < $1.path }) {
            // Length framing prevents ambiguity from delimiter/newline characters in filenames.
            let path = Data(record.path.utf8)
            digest.update(data: Data("\(path.count):".utf8))
            digest.update(data: path)
            digest.update(data: Data(record.hash.utf8))
        }
        return Summary(files: records.count, bytes: byteCount, fingerprint: hex(digest.finalize()),
                       paths: Set(records.map(\.path)), markdownBytes: markdownBytes, metadataHashes: metadataHashes)
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && fileType(lhs) == fileType(rhs)
    }

    private static func sameModification(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_size == rhs.st_size &&
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func readRegularFile(_ url: URL, root: URL, maximumBytes: Int) throws -> Data {
        guard isWithin(url, parent: root), url.resolvingSymlinksInPath() == url else { throw Failure.outsideRoot }
        let before = try statWithoutFollowing(url)
        guard fileType(before) != S_IFLNK else { throw Failure.symbolicLink }
        guard fileType(before) == S_IFREG else { throw Failure.nonRegularFile }
        guard before.st_nlink == 1 else { throw Failure.hardLink }
        guard before.st_size >= 0, before.st_size <= maximumBytes else { throw Failure.fileTooLarge }
        // O_NOFOLLOW also protects the final component if it changes after the lstat above.
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw Failure.unreadable }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, sameIdentity(before, opened),
              fileType(opened) == S_IFREG, opened.st_nlink == 1 else { throw Failure.changedDuringValidation }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.unreadable
            }
            if count == 0 { break }
            guard count <= maximumBytes - data.count else { throw Failure.fileTooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, sameIdentity(before, after), sameModification(before, after),
              data.count == after.st_size,
              url.resolvingSymlinksInPath() == url,
              sameIdentity(after, try statWithoutFollowing(url)) else { throw Failure.changedDuringValidation }
        return data
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
