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
//  Skipping & caps (see Documentation/Files Source (Skipping & Caps).md): code repos and
//  machine-generated datasets are pruned at the walk level (`pruneReason`), and `scan` bounds
//  every run — newest 1,000 per root, 100/300 per directory, 1-year age cutoff for Downloads.
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
    let perDirectoryCap: Int     // max candidates any single directory contributes (newest win)
    let maxAge: TimeInterval?    // drop files older than this (nil = no age cutoff)

    init(root: URL, label: String, perDirectoryCap: Int = 300, maxAge: TimeInterval? = nil) {
        self.root = root
        self.label = label
        self.perDirectoryCap = perDirectoryCap
        self.maxAge = maxAge
    }

    static let allowedExtensions: Set<String> = ["pdf", "doc", "docx", "md", "txt", "png", "jpg", "jpeg", "heic"]
    static let perRootCap = 1_000   // connector limit (June 10): newest 1,000 per root, every root
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]
    private static let maxContentChars = 8_000
    private static let pdfPageLimit = 3
    private static let imageMaxPixel = 1_280   // ≈ 720p short edge on 16:9

    // MARK: Skipping (code repos / dependency caches / datasets — Spotlight-style)

    /// Dependency / build / cache / dataset directories — pruned by name (subtree never walked).
    private static let skipDirNames: Set<String> = [
        "node_modules", "bower_components", "jspm_packages", "vendor", "pods", "carthage",
        "dist", "build", "target", ".build", "__pycache__", "venv", ".venv", ".tox",
        ".mypy_cache", ".pytest_cache", ".gradle", "deriveddata", ".dart_tool",
        ".next", ".nuxt", ".svelte-kit", ".angular",
        "site-packages", "dataset", "datasets", "corpus", "checkpoints",
    ]

    /// Hard "this is a code project" manifests — if present, skip the WHOLE folder. Deliberately
    /// NOT `.git` alone: Obsidian vaults & personal note repos are git repos full of markdown we
    /// WANT (`.git` only prunes alongside code signals — see `pruneReason`).
    private static let projectManifests: Set<String> = [
        "package.json", "Cargo.toml", "go.mod", "Package.swift", "pom.xml",
        "build.gradle", "build.gradle.kts", "composer.json", "Gemfile",
        "pyproject.toml", "Pipfile", "requirements.txt",
        "Makefile", "makefile", "CMakeLists.txt", "mix.exs", "deno.json", "build.sbt",
    ]

    /// Source-code extensions for the density heuristic — a folder that's mostly these is a code
    /// project even without a recognized manifest.
    private static let codeExtensions: Set<String> = [
        "py", "js", "jsx", "ts", "tsx", "mjs", "c", "h", "cpp", "cc", "hpp", "m", "mm",
        "swift", "java", "kt", "rs", "go", "rb", "php", "cs", "scala", "sh", "lua",
        "dart", "vue", "svelte", "sql", "pl", "r",
    ]

    /// Classic code-project directory names — with `.git` present, any of these confirms "repo".
    private static let codeDirNames: Set<String> = [
        "src", "lib", "tests", "test", "spec", "include", "cmd", "pkg", "sources", "bin",
    ]

    /// Why this directory's whole subtree is skipped — nil means walk in. Reads the directory
    /// listing ONCE and runs every check against it. `.app`/`.xcodeproj` bundle *descendants* +
    /// hidden dirs are already excluded by the enumerator options; this prunes at the parent.
    /// Internal (not private) so the skipping self-test's census can report reasons.
    static func pruneReason(_ dir: URL) -> String? {
        let name = dir.lastPathComponent
        if name.hasSuffix(".noindex") { return "noindex" }
        if skipDirNames.contains(name.lowercased()) { return "dep/build/dataset dir name" }

        guard let listing = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let names = Set(listing)
        if names.contains(".metadata_never_index") { return "never-index marker" }
        if names.contains(".obsidian") { return nil }   // Obsidian vault — always keep, no further checks

        if let manifest = projectManifests.first(where: { names.contains($0) }) { return "manifest: \(manifest)" }
        if let bundle = listing.first(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".sln") }) {
            return "project bundle: \(bundle)"
        }

        // Code-density: ≥10 extensioned entries and source code is the majority.
        let exts = listing.compactMap { n -> String? in
            let e = (n as NSString).pathExtension.lowercased()
            return e.isEmpty ? nil : e
        }
        let codeCount = exts.count(where: { codeExtensions.contains($0) })
        if exts.count >= 10, codeCount * 2 >= exts.count { return "code-density \(codeCount)/\(exts.count)" }

        // Bare repo: .git + any code file or a classic code dir (markdown-only git repos pass).
        let lowered = Set(listing.map { $0.lowercased() })
        if names.contains(".git"), codeCount > 0 || !codeDirNames.isDisjoint(with: lowered) {
            return ".git + code"
        }

        // Dataset: ≥100 files of one extension, ≥90% homogeneous, ≥80% machine-generated names.
        // Skipped ENTIRELY (decision June 10) — a sampled dataset still pollutes the vault.
        if exts.count >= 100 {
            var counts: [String: Int] = [:]
            for e in exts { counts[e, default: 0] += 1 }
            if let top = counts.max(by: { $0.value < $1.value }),
               top.value >= 100, top.value * 10 >= exts.count * 9 {
                let members = listing.filter { ($0 as NSString).pathExtension.lowercased() == top.key }
                let machine = members.count(where: { isDatasetName($0) })
                if machine * 5 >= members.count * 4 { return "dataset: \(top.value)×.\(top.key)" }
            }
        }
        return nil
    }

    /// Machine-generated filename (pure numbers, sequential frames/chunks, hashes, UUIDs) — the
    /// signature of a dataset, not a life. Screenshots & camera rolls are deliberately exempt
    /// (personal gold; the per-directory cap bounds their volume instead — decision June 10).
    private static func isDatasetName(_ name: String) -> Bool {
        let base = (name as NSString).deletingPathExtension.lowercased()
        if base.hasPrefix("screenshot") || base.hasPrefix("screen shot")
            || base.hasPrefix("cleanshot") || base.hasPrefix("img_") || base.hasPrefix("dsc") {
            return false
        }
        let patterns = [
            #"^\d+$"#,                                        // 000123
            #"^[a-z]+[-_ ]?\d{3,}$"#,                         // frame_0001 · part-00042 · chunk12345
            #"^[0-9a-f]{12,}$"#,                              // content hashes
            #"^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$"#,  // UUIDs
        ]
        return patterns.contains { base.range(of: $0, options: .regularExpression) != nil }
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
                if Self.pruneReason(url) != nil { enumerator.skipDescendants() }
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
        // Newest first, then the caps (connector-limits decision, June 10):
        //  • optional age cutoff (Downloads: 1 year — downloads age into junk; keepers elsewhere don't)
        //  • per-directory cap (Downloads 100 / others 300) — the bulk-dump backstop
        //  • per-root cap (newest 1,000, every root)
        let cutoff = maxAge.map { Date().timeIntervalSince1970 - $0 }
        var perDir: [String: Int] = [:]
        var kept: [Candidate] = []
        for row in rows.sorted(by: { $0.sortKey > $1.sortKey }) {
            if kept.count >= Self.perRootCap { break }
            if let cutoff, row.sortKey < cutoff { break }   // sorted → every later row is older
            guard let path = row.candidate.metadata["path"] else { continue }
            let dir = (path as NSString).deletingLastPathComponent
            if perDir[dir, default: 0] >= perDirectoryCap { continue }
            perDir[dir, default: 0] += 1
            kept.append(row.candidate)
        }
        return kept
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

    /// Connector limits (decision June 10): Downloads is the junk accumulator — tighter caps,
    /// plus a 1-year age cutoff (old downloads are noise; old Desktop/Documents files can be keepers).
    var perDirectoryCap: Int { self == .downloads ? 100 : 300 }
    var maxAge: TimeInterval? { self == .downloads ? 365 * 24 * 3_600 : nil }

    /// The fully configured source for this root (nil if the system folder can't be resolved).
    var source: FilesSource? {
        url.map { FilesSource(root: $0, label: label, perDirectoryCap: perDirectoryCap, maxAge: maxAge) }
    }

    /// The three standard folders, in display order.
    static let standard: [FileRoot] = [.downloads, .desktop, .documents]
}
