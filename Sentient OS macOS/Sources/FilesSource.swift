//
//  FilesSource.swift
//  Sentient OS macOS
//
//  Reads a user folder. Recurses subfolders, keeps only whitelisted extensions,
//  and extracts a BOUNDED amount of content per type:
//   • pdf              → first 3 pages of text (PDFKit)
//   • doc / docx       → text (NSAttributedString, best-effort; legacy .doc may be empty)
//   • md / txt         → text (char-capped)
//   • png/jpg/jpeg/heic → downsized JPEG (~720p) for the vision model (never decodes full 4K)
//
//  The model is given the home-relative path (e.g. ~/Downloads/Useless Stuff/x.jpg) + creation
//  date — the folder structure alone is strong signal for junk/intent.
//
//  POINTER: one per-bucket high-water mark per folder root (bucket "file:<FileRoot.id>"),
//  held in CycleStore and advanced by IterativeRun — no separate cursor object, no backfill engine.
//  eligibleFiles() keys each file on its pure addedToDirectoryDate (future-clamped, so a bad clock
//  can't poison the pointer) and returns the eligible set NEWEST-FIRST; IterativeRun's pointer (a
//  high-water mark, plus a floor while a first run is mid-descent) decides new-vs-done — so edits
//  never reprocess and a stopped run resumes.
//
//  Skipping & caps (see Documentation/Files Source (Skipping & Caps).md): three free layers, no
//  inference — subtree pruning (`pruneReason`: code repos, datasets, data/markup dumps), per-file
//  rejects (`fileRejectReason`: camera roll, lock/temp, boilerplate, empty, oversize), and caps
//  (newest 1,000/root · 300/dir · Downloads 1-year). The walk is bounded too — max depth 3, symlinks
//  skipped — and content extraction is timeout-guarded in IterativeRun.
//

import Foundation
import PDFKit
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct FilesSource: Sendable {
    let kind: SourceKind = .file
    let root: URL
    let label: String   // human folder name ("Downloads", "Desktop", a custom folder…) → stored as each artifact's `folder` tag
    let cursorKey: String        // pointer key for this root ("file:<FileRoot.id>")
    let perDirectoryCap: Int     // max candidates any single directory contributes (newest win)
    let maxAge: TimeInterval?    // drop files older than this (nil = no age cutoff)

    init(root: URL, label: String, cursorKey: String? = nil,
         perDirectoryCap: Int = 300, maxAge: TimeInterval? = nil) {
        self.root = root
        self.label = label
        self.cursorKey = cursorKey ?? "file:custom:" + root.path
        self.perDirectoryCap = perDirectoryCap
        self.maxAge = maxAge
    }

    static let allowedExtensions: Set<String> = ["pdf", "doc", "docx", "md", "txt", "png", "jpg", "jpeg", "heic"]
    static let perRootCap = 1_000   // connector limit (June 10): newest 1,000 per root, every root
    static let maxWalkDepth = 3                     // don't explore past 3 subfolder levels (bounds a pathological tree)
    static let maxFileBytes = 100 * 1_024 * 1_024   // skip files over ~100 MB — hang guard (never even open a giant file)
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]
    private static let maxContentChars = 8_000
    private static let pdfPageLimit = 3
    // Longest-edge cap for the JPEG we hand the vision model. Gemma 4's encoder resizes EVERYTHING
    // to 768×768 internally (per runtime logs: "Resize image … to 768x768"), so anything larger is
    // wasted bytes/decode/copy — 768 is model-native and ≤720p in area for any aspect. (The old 1280
    // only hit true 720p for 16:9 landscape; portrait/square scans stayed ~1.6 MP.) NOTE: this is the
    // INPUT shrink — what the model actually *processes* is governed by visualTokenBudget (Engine).
    private static let imageMaxPixel = 768

    // Test seam (DEBUG self-tests only — production never touches it): fixtures can't backdate
    // dateAdded on a real filesystem, so `testIgnoreDateAdded` makes file dates mtime-only.
    nonisolated(unsafe) static var testIgnoreDateAdded = false

    // MARK: Skipping (code repos / dependency caches / datasets — Spotlight-style)

    /// Dependency / build / cache / dataset directories — pruned by name (subtree never walked).
    private static let skipDirNames: Set<String> = [
        "node_modules", "bower_components", "jspm_packages", "vendor", "pods", "carthage",
        "dist", "build", "target", ".build", "__pycache__", "venv", ".venv", ".tox",
        ".mypy_cache", ".pytest_cache", ".gradle", "deriveddata", ".dart_tool",
        ".next", ".nuxt", ".svelte-kit", ".angular",
        "site-packages", "dataset", "datasets", "corpus", "checkpoints",
    ]

    /// Hard "this is a code project" manifests — if present, skip the WHOLE folder.
    private static let projectManifests: Set<String> = [
        "package.json", "Cargo.toml", "go.mod", "Package.swift", "pom.xml",
        "build.gradle", "build.gradle.kts", "composer.json", "Gemfile",
        "pyproject.toml", "Pipfile", "requirements.txt",
        "Makefile", "makefile", "CMakeLists.txt", "mix.exs", "deno.json", "build.sbt",
    ]

    /// Extensions for the density heuristic — a folder that's mostly these is a code project or a
    /// bulk data/markup dump (even without a manifest), so its few readable stragglers (a README, a
    /// stray screenshot) are project noise, not a life. The data/markup ones aren't in
    /// `allowedExtensions`, so they're never read as files anyway — listing them here only governs
    /// the subtree-skip decision (if >half a folder is JSON/HTML/notebooks, walking in is noise).
    private static let codeExtensions: Set<String> = [
        "py", "js", "jsx", "ts", "tsx", "mjs", "c", "h", "cpp", "cc", "hpp", "m", "mm",
        "swift", "java", "kt", "rs", "go", "rb", "php", "cs", "scala", "sh", "lua",
        "dart", "vue", "svelte", "sql", "pl", "r",
        // Data / markup — bulk presence signals a project or data dump, not personal content.
        "json", "html", "htm", "css", "scss", "less", "ipynb", "xml", "yaml", "yml", "toml",
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
        // Obsidian/Logseq vaults — always keep, no further checks (even git-synced ones).
        if names.contains(".obsidian") || names.contains("logseq") { return nil }

        // Any other git repo is a code project (decision June 11 — surveyed 38 repos across the
        // standard folders: zero were notes). The 1% who git-sync a plain markdown journal have a
        // working escape hatch: explicitly added roots are never themselves prune-checked.
        if names.contains(".git") { return ".git" }

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

    // MARK: File-level rejects (content-free — name & size only; decided 2026-06-25)

    /// Obvious noise we refuse from the NAME and SIZE alone — never by reading the file. Every item
    /// rejected here is one model call saved. Runs per file in eligibleFiles(), after the extension
    /// whitelist. (Subtree-level skips live in pruneReason; this is the per-file companion.)
    static func fileRejectReason(name: String, ext: String, size: Int?) -> String? {
        // App lock / temp owner files (e.g. Word's "~$Report.docx") — garbage content.
        if name.hasPrefix("~$") || name.hasPrefix(".~") { return "lock/temp file" }
        // Empty stub — a model call for nothing.
        if let size, size == 0 { return "empty file" }
        // Hang guard — refuse to even open something huge (a 2 GB PDF can stall the run).
        if let size, size > maxFileBytes { return "oversize" }
        // Boilerplate that ships inside downloaded tools/zips — never the user's own life.
        if boilerplateNames.contains((name as NSString).deletingPathExtension.lowercased()) {
            return "boilerplate doc"
        }
        // Camera-roll photos — describing random pictures adds nothing (decided: drop outright).
        // Screenshots are deliberately NOT here: a screenshot can hold a ticket/address/confirmation.
        if imageExtensions.contains(ext), isCameraRollName(name) { return "camera roll" }
        return nil
    }

    /// Boilerplate filenames bundled with software/downloads — matched on the basename, any extension.
    /// (A real code repo is already pruned by .git/manifest; this catches a loose README/LICENSE that
    /// got unzipped into Downloads on its own.)
    private static let boilerplateNames: Set<String> = [
        "readme", "license", "licence", "copying", "notice",
        "changelog", "authors", "contributing", "code_of_conduct", "eula",
    ]

    /// Phone/camera photo filenames — the signature of a camera roll, not a life: iPhone (IMG_),
    /// Pixel (PXL_), generic cameras (DSC/DSCN/DSCF), GoPro (GOPR), panoramas, motion photos, burst
    /// shots, and WhatsApp media (IMG-…-WA…). Screenshots are deliberately excluded (kept as keepers).
    private static func isCameraRollName(_ name: String) -> Bool {
        let base = (name as NSString).deletingPathExtension.lowercased()
        let camera = ["img_", "img-", "pxl_", "dsc", "mvimg", "pano", "gopr", "burst"]
        return camera.contains { base.hasPrefix($0) }
    }

    // MARK: Pointer encoding — "(epochSeconds|path)", path = same-second tiebreak

    static func pointerValue(date: Date, path: String) -> String {
        "\(date.timeIntervalSince1970)|\(path)"
    }

    // MARK: Eligible files (the files-iterative system's flat, pointer-free view)

    /// The current eligible set for this root, for the iterative system (IterativeRun via
    /// FilesConnector). Same
    /// skip rules (`pruneReason`) and caps (`cappedNewestFirst`: 1,000/root · 300/dir · Downloads
    /// 1-yr) as `scan`, but deliberately DIFFERENT in two ways:
    ///   • keyed on PURE `addedToDirectoryDate` (a file's "date added" — what Finder shows), NOT
    ///     scan's max(dateAdded, mtime, ancestor). The interval pointer reprocesses nothing on
    ///     edits, so only date-added matters.
    ///   • NO cursor / backfill / hold-back logic — the FolderPointer interval decides new-vs-done.
    /// Returns newest-first; each Candidate's `itemDate` IS its date added (so ItemKey =
    /// (itemDate, path)). Reuse `load(_:)` for content extraction.
    func eligibleFiles() -> [Candidate] {
        let now = Date()
        let rootDepth = root.pathComponents.count
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                         .fileSizeKey, .creationDateKey, .addedToDirectoryDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var rows: [(candidate: Candidate, sortKey: Double)] = []
        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: keys)
            // Never follow symlinks — they can form loops that never finish the walk.
            if vals?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if vals?.isDirectory == true {
                // Skip the subtree if it's noise (pruneReason) OR too deep (bounds a pathological tree).
                if Self.pruneReason(url) != nil
                    || url.pathComponents.count - rootDepth > Self.maxWalkDepth {
                    enumerator.skipDescendants()
                }
                continue   // directories are never candidates themselves
            }
            guard vals?.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard Self.allowedExtensions.contains(ext) else { continue }
            // Content-free per-file rejects (camera roll, lock/temp, boilerplate, empty, oversize).
            if Self.fileRejectReason(name: url.lastPathComponent, ext: ext, size: vals?.fileSize) != nil {
                continue
            }

            // Pure date added, future-clamped. A file with no recorded date-added sorts to the
            // bottom (.distantPast) rather than poisoning the newest end.
            let added = min(vals?.addedToDirectoryDate ?? .distantPast, now)

            var meta: [String: String] = [
                "path": url.path,
                "displayPath": Self.homeRelativePath(url),
                "name": url.lastPathComponent,
                "folder": label,
            ]
            if let created = vals?.creationDate { meta["created"] = Self.dateString(created) }

            let candidate = Candidate(id: "file:\(url.path)", kind: .file,
                                      cursorKey: cursorKey,
                                      cursorValue: Self.pointerValue(date: added, path: url.path),
                                      itemDate: added, metadata: meta)
            rows.append((candidate, added.timeIntervalSince1970))
        }
        let kept = cappedNewestFirst(rows, budget: Self.perRootCap, now: now)
        // §7.8: per-root yield collapse — if a root that used to surface many files suddenly yields
        // zero, an over-skip regression (a new prune/cap bug, like B8) is silently eating it. Keyed
        // per root (cursorKey = "file:<root.id>"), the Files anomaly grain.
        SourceHealth.checkListingCollapse(source: "files", bucketKey: cursorKey, count: kept.count)
        return kept
    }

    /// Newest-first selection under the connector caps (June 10–11 decisions):
    ///  • optional age cutoff (Downloads: 1 year — downloads age into junk; keepers elsewhere don't)
    ///  • per-directory cap (300, every root) — the bulk-dump backstop
    ///  • `budget` — the per-root cap, or what's left of a backfill's descent budget
    private func cappedNewestFirst(_ rows: [(candidate: Candidate, sortKey: Double)],
                                   budget: Int, now: Date) -> [Candidate] {
        let cutoff = maxAge.map { now.timeIntervalSince1970 - $0 }
        var perDir: [String: Int] = [:]
        var kept: [Candidate] = []
        for row in rows.sorted(by: { $0.sortKey > $1.sortKey }) {
            if kept.count >= budget { break }
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


    /// Content extraction for the files-iterative
    /// `FilesConnector`. Stateless: reads only `candidate.metadata["path"]`.
    static func loadArtifact(_ candidate: Candidate) throws -> Artifact {
        guard let path = candidate.metadata["path"] else { throw FilesError.noPath }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            return Artifact(candidate: candidate, imageData: try downsampledJPEG(url))
        }
        return Artifact(candidate: candidate, text: try extractText(url: url, ext: ext))
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

/// A user folder the Files pipeline can analyze. The dev picker (RootView) offers the three
/// standard folders plus any number of custom-chosen ones; each selected root becomes its own
/// `FilesSource` pass with its OWN pointer. The product rule: "suggest Desktop + Downloads,
/// but the user chooses the folders."
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

    /// Connector limits (June 10–11): 1,000/root + 300/dir everywhere (the FilesSource defaults);
    /// Downloads additionally gets a 1-year age cutoff (old downloads are noise; old
    /// Desktop/Documents files can be keepers).
    var maxAge: TimeInterval? { self == .downloads ? 365 * 24 * 3_600 : nil }

    /// The fully configured source for this root (nil if the system folder can't be resolved).
    /// The pointer key uses `id` (never `label` — two custom folders can share a name).
    var source: FilesSource? {
        url.map { FilesSource(root: $0, label: label, cursorKey: "file:\(id)", maxAge: maxAge) }
    }

    /// The three standard folders, in display order.
    static let standard: [FileRoot] = [.downloads, .desktop, .documents]
}
