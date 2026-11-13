import AppKit
import PDFKit
@preconcurrency import ApplicationServices

struct SummarySource: Sendable {
    var text = ""
    var title = ""
    var url: String?
    var application = ""
    var truncated = false
    var image: Data?
    var scope = "loaded document"
    var offscreenTextElements = 0

    /// A loading hint only. The relay still confirms whether a transcript was fetched.
    var isYouTubeVideo: Bool {
        guard let url, let parts = URLComponents(string: url),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == (scheme == "https" ? 443 : 80),
              let host = parts.host?.lowercased() else { return false }
        let path = parts.percentEncodedPath
        let id: String?
        if host == "youtu.be" { id = String(path.dropFirst()) }
        else if ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host) {
            if path == "/watch" { id = parts.queryItems?.first(where: { $0.name == "v" })?.value }
            else {
                let components = path.split(separator: "/")
                guard components.count == 2, ["shorts", "live", "embed"].contains(String(components[0])),
                      path == "/\(components[0])/\(components[1])" || path == "/\(components[0])/\(components[1])/" else { return false }
                id = String(components[1])
            }
        } else { return false }
        return id?.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }
}

/// Reads the application's accessibility document, never operates its controls or enables a debugger.
nonisolated enum SummaryAccessibility {
    static let maximumTextBytes = 26_000 // Even byte-level tokenization leaves room below 30k input tokens.
    struct Target: @unchecked Sendable {
        let pid: pid_t; let name: String; let browser: Bool
        var window: AXUIElement? = nil
        var title: String? = nil
        var bundleIdentifier: String? = nil
        var windowTitle: String? { title ?? window.flatMap { SummaryAccessibility.attribute($0, "AXTitle") as? String } }
        var windowFrame: CGRect? { window.flatMap { SummaryAccessibility.rect($0) } }
    }
    enum Failure: LocalizedError, Equatable { case permission, unavailable, ownApplication
        var errorDescription: String? {
            switch self {
            case .ownApplication: "Switch to another app to summarize it."
            case .permission: "Allow Accessibility so Sentient can read the text you want summarized."
            case .unavailable: "This app did not expose readable text. Try opening the document or enable Screen Recording for a visual summary."
            }
        }
    }
    @MainActor static func target() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return target(for: app)
    }
    @MainActor static func target(for app: NSRunningApplication) -> Target {
        let browsers = ["com.microsoft.edgemac", "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "company.thebrowser.dia", "com.brave.Browser", "org.mozilla.firefox"]
        // Never re-enter our own SwiftUI accessibility provider while resolving a source.
        guard app.processIdentifier != getpid() else {
            return Target(pid: app.processIdentifier, name: app.localizedName ?? "Sentient",
                browser: false, bundleIdentifier: app.bundleIdentifier)
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.08)
        let window = element(root, "AXFocusedWindow") ?? element(root, "AXMainWindow")
        return Target(pid: app.processIdentifier, name: app.localizedName ?? "App", browser: browsers.contains(app.bundleIdentifier ?? ""), window: window, title: window.flatMap { attribute($0, "AXTitle") as? String }, bundleIdentifier: app.bundleIdentifier)
    }
    static func read(_ target: Target) throws -> SummarySource {
        guard target.pid != getpid() else { throw Failure.ownApplication }
        guard AXIsProcessTrusted() else { throw Failure.permission }
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        let originalTitle = target.title ?? target.window.flatMap { attribute($0, "AXTitle") as? String }
        let identifier = target.bundleIdentifier ?? NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier
        // Chromium/Electron lazily create their accessibility tree when an assistive client asks.
        for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            if (attribute(app, name) as? Bool) != true { _ = AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanTrue) }
        }
        var result: SummarySource?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let windows = attribute(app, "AXWindows") as? [AXUIElement] ?? []
            // Enabling Electron accessibility can replace its window AX object. Resolve the
            // same titled window again on retry, rather than falling through to another document.
            let refreshed = windows.first { originalTitle != nil && (attribute($0, "AXTitle") as? String) == originalTitle }
            let window = attempt == 0 ? target.window ?? refreshed : refreshed
            if let window = window ?? (originalTitle == nil ? element(app, "AXFocusedWindow") ?? element(app, "AXMainWindow") ?? windows.first : nil) {
                if let pdf = readPDF(window, target: target) { return pdf }
                if let identifier, let profile = SummaryConversation.App(rawValue: identifier) {
                    return try SummaryConversation.read(window: window, app: profile, application: target.name)
                }
                result = scan(window, target: target)
                if !(result?.text.isEmpty ?? true) { break }
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.15) }
        }
        // Even an inaccessible video player can expose its document URL. Preserve it
        // for native-transcript lookup while the screenshot supplies visual context.
        guard let result, !result.text.isEmpty || result.url != nil else { throw Failure.unavailable }
        return result
    }
    private static func readPDF(_ window: AXUIElement, target: Target) -> SummarySource? {
        guard let raw = attribute(window, "AXDocument") as? String,
              let url = URL(string: raw) else { return nil }
        return readPDF(at: url, application: target.name)
    }
    static func readPDF(at url: URL, application: String) -> SummarySource? {
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf",
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? Int.max) <= 50_000_000,
              let pdf = PDFDocument(url: url), !pdf.isLocked else { return nil }
        let start = Date()
        var pages: [String] = [], bytes = 0, limited = false
        for index in 0..<min(pdf.pageCount, 1000) {
            if Task.isCancelled || Date().timeIntervalSince(start) > 5 || bytes > 400_000 { limited = true; break }
            if let text = pdf.page(at: index)?.string, !text.isEmpty {
                pages.append("[Page \(index + 1)]\n" + text); bytes += text.utf8.count
            }
        }
        guard !pages.isEmpty else { return nil }
        let text = pages.joined(separator: "\n\n")
        return SummarySource(text: bounded(text, maximumBytes: maximumTextBytes), title: url.lastPathComponent,
            application: String(application.prefix(50)), truncated: limited || pdf.pageCount > 1000 || text.utf8.count > maximumTextBytes,
            scope: "active PDF document, including offscreen pages")
    }
    private static func scan(_ window: AXUIElement, target: Target) -> SummarySource {
        var result = SummarySource(title: String((attribute(window, "AXTitle") as? String ?? "").prefix(250)), application: String(target.name.prefix(50)))
        let began = Date()
        let windowRect = rect(window)
        var pending: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
        var seen: [UInt: [AXUIElement]] = [:]
        var document: [String] = [], other: [String] = []
        var nodes = 0, bytes = 0
        while let (node, depth, insideWeb) = pending.popLast() {
            if Task.isCancelled || nodes >= 12_000 || bytes >= 400_000 || Date().timeIntervalSince(began) > 6 { result.truncated = true; break }
            if depth > 80 { result.truncated = true; continue }
            let hash = CFHash(node)
            if seen[hash]?.contains(where: { CFEqual($0, node) }) == true { continue }
            seen[hash, default: []].append(node); nodes += 1
            AXUIElementSetMessagingTimeout(node, 0.08)
            let role = attribute(node, "AXRole") as? String ?? ""
            if ["AXToolbar", "AXMenuBar", "AXMenu"].contains(role) { continue }
            let web = insideWeb || ["AXWebArea", "AXDocument", "AXTextArea"].contains(role)
            if (attribute(node, "AXSubrole") as? String) == "AXSecureTextField" || (attribute(node, "AXProtectedContent") as? Bool) == true { continue }
            if role == "AXWebArea", result.url == nil, let url = attribute(node, "AXURL") {
                let value = (url as? URL)?.absoluteString ?? (url as? String)
                if let value, value.utf8.count <= 2_000, value.hasPrefix("https://") || value.hasPrefix("http://") { result.url = value }
            }
            if ["AXStaticText", "AXTextArea", "AXHeading", "AXLink", "AXListMarker"].contains(role) {
                var string: String?
                if let count = attribute(node, "AXNumberOfCharacters") as? Int, count > 32_768 {
                    // A native editor may expose its entire file in one AXTextArea. Read
                    // small ranges across it, including the end, rather than requesting a huge value.
                    var excerpts: [String] = []
                    let width = 4_000
                    for index in 0..<6 {
                        if Task.isCancelled || Date().timeIntervalSince(began) > 6 { break }
                        var range = CFRange(location: index * max(0, count - width) / 5, length: min(width, count))
                        if let axRange = AXValueCreate(.cfRange, &range) {
                            var value: CFTypeRef?
                            if AXUIElementCopyParameterizedAttributeValue(node, "AXStringForRange" as CFString, axRange, &value) == .success,
                               let part = value as? String { excerpts.append(part) }
                        }
                    }
                    string = excerpts.isEmpty ? attribute(node, "AXValue") as? String : excerpts.joined(separator: "\n[... document excerpt gap ...]\n")
                    result.truncated = true
                } else { string = attribute(node, "AXValue") as? String }
                if string?.isEmpty != false { string = attribute(node, "AXTitle") as? String }
                if string?.isEmpty != false && role == "AXLink" { string = attribute(node, "AXDescription") as? String }
                let raw = (string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // A long paragraph may be one AXStaticText value. Prefix-only truncation
                // silently discarded its ending before the document budget was applied.
                let line = bounded(raw, maximumBytes: maximumTextBytes)
                if raw.utf8.count > maximumTextBytes { result.truncated = true }
                if !line.isEmpty {
                    bytes += line.utf8.count
                    if let bounds = rect(node), let windowRect, (bounds.height <= 1 || !bounds.intersects(windowRect)) { result.offscreenTextElements += 1 }
                    if web {
                        if document.last != line { document.append(line) }
                    } else if other.last != line { other.append(line) }
                }
            }
            var count: CFIndex = 0
            if AXUIElementGetAttributeValueCount(node, "AXChildren" as CFString, &count) == .success, count > 0 {
                let limit = min(count, max(0, 12_000 - nodes - pending.count))
                var children: [AXUIElement] = []
                for offset in stride(from: 0, to: limit, by: 128) {
                    if Task.isCancelled || Date().timeIntervalSince(began) > 6 { result.truncated = true; break }
                    var array: CFArray?
                    if AXUIElementCopyAttributeValues(node, "AXChildren" as CFString, offset, min(128, limit - offset), &array) == .success,
                       let values = array as? [AXUIElement] { children += values }
                }
                if limit < count { result.truncated = true }
                pending += children.reversed().map { ($0, depth + 1, web) }
            }
        }
        let lines = document.isEmpty && !target.browser ? other : document
        let joined = lines.joined(separator: "\n")
        result.text = bounded(joined, maximumBytes: maximumTextBytes)
        result.truncated = result.truncated || joined.utf8.count > maximumTextBytes
        result.scope = target.browser ? "whole loaded page (including offscreen text)" : "whole loaded document in the active window (including offscreen text)"
        return result
    }
    static func bounded(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        // Keep the document opening and ending, sampling the middle in order rather than
        // letting navigation or an enormous early thread consume the whole allowance.
        let chunks = text.components(separatedBy: "\n")
        let allowance = max(1, (maximumBytes - 180) / 3)
        func prefixBytes(_ value: String, _ limit: Int) -> String {
            var result = "", used = 0
            for c in value { let n = String(c).utf8.count; if used + n > limit { break }; result.append(c); used += n }
            return result
        }
        let head = prefixBytes(text, allowance)
        let tail = String(prefixBytes(String(text.reversed()), allowance).reversed())
        let strideSize = max(1, chunks.count / 24)
        let sampled = chunks.enumerated().filter { $0.offset % strideSize == 0 }.map(\.element).joined(separator: "\n")
        return head + "\n[Content abbreviated; representative middle excerpts follow]\n" + prefixBytes(sampled, allowance)
            + "\n[Final loaded content]\n" + tail
    }
    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success ? value : nil
    }
    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    static func rect(_ node: AXUIElement) -> CGRect? {
        guard let p = attribute(node, "AXPosition"), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(node, "AXSize"), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
