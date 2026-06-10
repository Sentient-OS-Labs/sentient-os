//
//  FilesSource.swift
//  Sentient OS macOS
//
//  DataSource over a user folder (Phase 1b starts with ~/Downloads). Recurses subfolders,
//  keeps only whitelisted extensions, and extracts a BOUNDED amount of content per type:
//   • pdf              → first 3 pages of text (PDFKit)
//   • doc / docx       → text (NSAttributedString, best-effort; legacy .doc may be empty)
//   • md / txt         → text (char-capped)
//   • png/jpg/jpeg/heic → downsized JPEG (~720p) for the vision model (never decodes full 4K)
//
//  The model is given the home-relative path (e.g. ~/Downloads/Useless Stuff/x.jpg) + creation
//  date — the folder structure alone is strong signal for junk/intent.
//

import Foundation
import PDFKit
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct FilesSource: DataSource, Sendable {
    let kind: SourceKind = .file
    let root: URL
    let label: String   // human folder name ("Downloads", "Desktop", a custom folder…) → stored as each artifact's `folder` tag

    static let allowedExtensions: Set<String> = ["pdf", "doc", "docx", "md", "txt", "png", "jpg", "jpeg", "heic"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]
    private static let maxContentChars = 8_000
    private static let pdfPageLimit = 3
    private static let imageMaxPixel = 1_280   // ≈ 720p short edge on 16:9

    // MARK: Pruning (skip code repos / dependency caches — Spotlight-style)

    /// Dependency / build / cache directories — pruned by name (their subtree is never walked).
    private static let skipDirNames: Set<String> = [
        "node_modules", "bower_components", "jspm_packages", "vendor", "pods", "carthage",
        "dist", "build", "target", ".build", "__pycache__", "venv", ".venv", ".tox",
        ".mypy_cache", ".pytest_cache", ".gradle", "deriveddata", ".dart_tool",
        ".next", ".nuxt", ".svelte-kit", ".angular",
    ]

    /// Hard "this is a code project" manifests — if present, skip the WHOLE folder. Deliberately
    /// NOT `.git`: Obsidian vaults & personal note repos are git repos full of markdown we WANT.
    private static let projectManifests: [String] = [
        "package.json", "Cargo.toml", "go.mod", "Package.swift", "pom.xml",
        "build.gradle", "build.gradle.kts", "composer.json", "Gemfile",
        "pyproject.toml", "Pipfile", "requirements.txt",
    ]

    /// Should this directory's whole subtree be skipped? (dep/build dir · *.noindex · OS
    /// never-index marker · code-project root). `.app`/`.xcodeproj` bundles + hidden dirs are
    /// already handled by the enumerator options.
    private static func shouldPrune(_ dir: URL) -> Bool {
        let name = dir.lastPathComponent
        if name.hasSuffix(".noindex") { return true }
        if skipDirNames.contains(name.lowercased()) { return true }
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent(".metadata_never_index").path) { return true }
        return projectManifests.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    // MARK: Scan (cheap — stat only, recurses subfolders)

    func scan(since cursor: String?) throws -> [Candidate] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var rows: [(candidate: Candidate, sortKey: Double)] = []
        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: keys)

            // Prune at the WALK level: skipDescendants() means nothing inside is ever yielded,
            // so it never becomes a Candidate / hits the ledger / sees inference.
            if vals?.isDirectory == true {
                if Self.shouldPrune(url) { enumerator.skipDescendants() }
                continue   // directories are never candidates themselves
            }

            guard vals?.isRegularFile == true,
                  Self.allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }

            let size = vals?.fileSize ?? 0
            let mtime = vals?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let created = vals?.creationDate
            let signature = "\(size):\(Int(mtime))"

            var meta: [String: String] = [
                "path": url.path,
                "displayPath": Self.homeRelativePath(url),
                "name": url.lastPathComponent,
                "folder": label,
            ]
            if let created { meta["created"] = Self.dateString(created) }

            let candidate = Candidate(id: "file:\(url.path)", kind: .file, signature: signature, metadata: meta)
            rows.append((candidate, created?.timeIntervalSince1970 ?? mtime))
        }
        // Newest first — nicer for incremental runs + manual testing.
        return rows.sorted { $0.sortKey > $1.sortKey }.map(\.candidate)
    }

    // MARK: Load (expensive — extract content)

    func load(_ candidate: Candidate) throws -> Artifact {
        guard let path = candidate.metadata["path"] else { throw FilesError.noPath }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        if Self.imageExtensions.contains(ext) {
            return Artifact(candidate: candidate, imageData: try Self.downsampledJPEG(url))
        }
        return Artifact(candidate: candidate, text: try Self.extractText(url: url, ext: ext))
    }

    // MARK: Text extraction

    private static func extractText(url: URL, ext: String) throws -> String {
        let raw: String
        switch ext {
        case "pdf":          raw = pdfText(url)
        case "doc", "docx":  raw = wordText(url)
        default:             raw = plainText(url)   // md, txt
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxContentChars))
    }

    private static func pdfText(_ url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var out = ""
        for i in 0..<min(pdfPageLimit, doc.pageCount) {
            if let s = doc.page(at: i)?.string { out += s + "\n" }
            if out.count >= maxContentChars { break }
        }
        return out
    }

    private static func wordText(_ url: URL) -> String {
        // Auto-detects docx/doc/rtf by content; best-effort (legacy binary .doc may return "").
        (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string ?? ""
    }

    private static func plainText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
    }

    // MARK: Image downsample (ImageIO thumbnail → ~720p JPEG, no full-res decode)

    private static func downsampledJPEG(_ url: URL) throws -> Data {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw FilesError.imageDecodeFailed }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: imageMaxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw FilesError.imageDecodeFailed
        }
        // Encode via ImageIO (not NSBitmapImageRep). JPEG is opaque, so this drops the stray
        // alpha channel the thumbnail carries — avoids the "opaque image with alpha → double the
        // memory" warning and the wasted decode memory.
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw FilesError.imageEncodeFailed
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FilesError.imageEncodeFailed }
        return out as Data
    }

    // MARK: Helpers

    /// Home-relative display path, e.g. ~/Downloads/Useless Stuff/x.jpg — strong context for the model.
    private static func homeRelativePath(_ url: URL) -> String {
        let full = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return full.hasPrefix(home) ? "~" + full.dropFirst(home.count) : full
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
    private static func dateString(_ d: Date) -> String { dateFormatter.string(from: d) }

    enum FilesError: Error { case noPath, imageDecodeFailed, imageEncodeFailed }
}

// MARK: - FileRoot (which folders the Files pipeline can run over)

/// A user folder the Files pipeline can analyze. The DEBUG picker (RootView) offers the three
/// standard folders plus any number of custom-chosen ones; each selected root becomes its own
/// `FilesSource` pass. Arch §3.4: "suggest Desktop + Downloads, but the user chooses the folders."
enum FileRoot: Hashable, Identifiable {
    case downloads
    case desktop
    case documents
    case custom(URL)

    var id: String {
        switch self {
        case .downloads:        return "downloads"
        case .desktop:          return "desktop"
        case .documents:        return "documents"
        case .custom(let url):  return "custom:" + url.path
        }
    }

    /// On-disk location (nil only if the system can't resolve a standard folder).
    var url: URL? {
        let fm = FileManager.default
        switch self {
        case .downloads:        return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .desktop:          return fm.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .documents:        return fm.urls(for: .documentDirectory, in: .userDomainMask).first
        case .custom(let url):  return url
        }
    }

    /// Human label — also what we persist as each artifact's `folder` tag.
    var label: String {
        switch self {
        case .downloads:        return "Downloads"
        case .desktop:          return "Desktop"
        case .documents:        return "Documents"
        case .custom(let url):  return url.lastPathComponent
        }
    }

    /// The three standard folders, in display order.
    static let standard: [FileRoot] = [.downloads, .desktop, .documents]
}
