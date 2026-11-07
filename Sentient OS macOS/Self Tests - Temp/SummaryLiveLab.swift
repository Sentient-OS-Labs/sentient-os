#if DEBUG
import AppKit
import ApplicationServices

/// Explicit opt-in: exercises the actual signed app, real AX permission, production relay and
/// native summary panels. The private fixture directory retains receipts for manual review.
@MainActor enum SummaryLiveLab {
    static func run(root: URL) async throws -> [String: Bool] {
        guard (try? String(contentsOf: root.appendingPathComponent("allow-live-summary"), encoding: .utf8)) == "authorized\n" else { throw Failure.notAuthorized }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("summary-audit-cases.json").path) {
            return try await audit(root: root)
        }
        UserDefaults.standard.set(true, forKey: "summary.disableScreenshots")
        let directory = root.appendingPathComponent("summary-live-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks: [String: Bool] = [:], records: [[String: Any]] = []
        var apps = [("com.microsoft.edgemac", "most useless piece"), ("com.google.Chrome", "most useless piece"),
                    ("com.apple.Safari", "most useless piece"), ("com.anthropic.claudefordesktop", "Claude"),
                    ("com.apple.Preview", "document.pdf"), ("com.apple.Preview", "long-document.pdf")]
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("youtube-only").path) { apps = [("com.microsoft.edgemac", "YouTube")] }
        let sessions = SummarySessions()
        defer { sessions.dismiss() }
        for (identifier, title) in apps {
            let caseName = identifier + (title == "long-document.pdf" ? "-long" : "")
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first else { throw Failure.missingApp }
            let application = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(application, "AXWindows" as CFString, &value)
            let windows = value as? [AXUIElement] ?? []
            guard let window = windows.first(where: { window in
                var text: CFTypeRef?; AXUIElementCopyAttributeValue(window, "AXTitle" as CFString, &text)
                let value = text as? String ?? ""
                return identifier == "com.apple.Preview" ? value.hasPrefix(title) : value.localizedCaseInsensitiveContains(title)
            }) else { throw Failure.missingWindow }
            let start = Date()
            let summary = sessions.start(displayID: CGMainDisplayID(), target: .init(pid: app.processIdentifier,
                name: app.localizedName ?? identifier, browser: identifier.contains("edgemac") || identifier.contains("Chrome") || identifier.contains("Safari"), window: window))
            var sawStream = false
            while summary.isBusy, Date().timeIntervalSince(start) < 55 {
                if summary.phase == .streaming { sawStream = true }
                try await Task.sleep(for: .milliseconds(40))
            }
            checks[caseName + "-completed"] = summary.phase == .complete && !summary.text.isEmpty
            checks[caseName + "-text-source"] = summary.sourceInfo?.kind == .accessibility
            checks[caseName + "-native-panel"] = summary.fixtureWindow?.isVisible == true
            checks[caseName + "-streamed"] = sawStream
            try await Task.sleep(for: .milliseconds(700))
            if let host = summary.fixtureWindow?.contentView {
                _ = try await SidekickPolishLab.capture(host, name: caseName, directory: directory)
                checks[caseName + "-rendered"] = descendants(host).compactMap { $0 as? NSTextView }.contains { $0.string.count > 50 }
            }
            if title == "long-document.pdf" {
                checks[caseName + "-final-page-decision"] = summary.text.lowercased().contains("monday") && summary.text.lowercased().contains("rowan")
                checks[caseName + "-bounded-excerpts"] = summary.sourceInfo?.truncated == true
            } else if title == "document.pdf" {
                checks[caseName + "-last-page-read"] = summary.text.lowercased().contains("final")
            } else if title == "most useless piece" {
                checks[caseName + "-correct-page"] = summary.text.lowercased().contains("workday")
            }
            records.append(["application": identifier, "case": caseName, "phase": String(describing: summary.phase), "source": summary.sourceLabel,
                "summary": summary.text, "error": summary.error ?? "", "seconds": Date().timeIntervalSince(start)])
            // Keep the previous result while starting the next, exercising independent windows.
            if sessions.sessions.count > 2 { sessions.sessions.first?.dismiss() }
            try JSONSerialization.data(withJSONObject: ["checks": checks, "results": records, "source_screenshots_disabled": true], options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("summary-live.json"), options: .atomic)
            guard summary.phase == .complete else { throw Failure.summary }
        }
        checks["independent-results"] = sessions.sessions.count == min(2, apps.count) && sessions.sessions.allSatisfy { $0.phase == .complete }
        sessions.dismiss()
        checks["all-panels-dismissed"] = sessions.sessions.isEmpty
        try JSONSerialization.data(withJSONObject: ["checks": checks, "results": records, "source_screenshots_disabled": true], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("summary-live.json"), options: .atomic)
        guard checks.values.allSatisfy({ $0 }) else { throw Failure.checks }
        return checks
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private struct AuditCase: Decodable {
        let name: String
        let application: String
        let title: String
        let includes: [String]
        let excludes: [String]
        let urlContains: String?
        let minimumOffscreen: Int
        let screenshot: Bool
        let infer: Bool
        let summaryIncludes: [String]?
        let expectedSource: String?
        let checkPresentation: Bool?
        let expectedScope: String?
    }
    private static func audit(root: URL) async throws -> [String: Bool] {
        let cases = try JSONDecoder().decode([AuditCase].self, from: Data(contentsOf: root.appendingPathComponent("summary-audit-cases.json")))
        var checks: [String: Bool] = [:], results: [[String: Any]] = []
        for item in cases {
            let began = Date()
            do {
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: item.application).first else { throw Failure.missingApp }
                let application = AXUIElementCreateApplication(app.processIdentifier)
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(application, "AXWindows" as CFString, &value)
                let windows = value as? [AXUIElement] ?? []
                guard let window = windows.first(where: { window in
                    var title: CFTypeRef?; AXUIElementCopyAttributeValue(window, "AXTitle" as CFString, &title)
                    return (title as? String ?? "").localizedCaseInsensitiveContains(item.title)
                }) else { throw Failure.missingWindow }
                let target = SummaryAccessibility.Target(pid: app.processIdentifier, name: app.localizedName ?? item.application,
                    browser: !["com.anthropic.claudefordesktop", "com.openai.codex", "net.whatsapp.WhatsApp", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap"].contains(item.application), window: window, bundleIdentifier: item.application)
                UserDefaults.standard.set(!item.screenshot, forKey: "summary.disableScreenshots")
                let source = try await SummaryCapture.capture(displayID: ScreenCapture.summaryDisplay() ?? CGMainDisplayID(), target: target)
                let captureSeconds = Date().timeIntervalSince(began)
                checks[item.name + "-required-text"] = item.includes.allSatisfy { source.text.contains($0) }
                checks[item.name + "-excluded-text"] = item.excludes.allSatisfy { !source.text.contains($0) }
                checks[item.name + "-offscreen"] = source.offscreenTextElements >= item.minimumOffscreen
                checks[item.name + "-url"] = item.urlContains.map { source.url?.contains($0) == true } ?? true
                checks[item.name + "-image"] = (source.image != nil) == item.screenshot
                checks[item.name + "-bounded"] = source.text.utf8.count <= SummaryAccessibility.maximumTextBytes
                if let expected = item.expectedScope { checks[item.name + "-scope"] = source.scope.contains(expected) }
                try source.text.write(to: root.appendingPathComponent(item.name + "-source.txt"), atomically: true, encoding: .utf8)
                if let image = source.image { try image.write(to: root.appendingPathComponent(item.name + "-screen.jpg")) }
                let request = try SummarizeInference.request(base: ScreenRelay.url!, source: source, preference: "", identity: "fixture-payload-validation")
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                checks[item.name + "-request-image"] = (body["image"] != nil) == item.screenshot
                var result: [String: Any] = ["name": item.name, "application": item.application, "text_bytes": source.text.utf8.count,
                    "image_bytes": source.image?.count ?? 0, "offscreen_elements": source.offscreenTextElements,
                    "truncated": source.truncated, "url": source.url ?? "", "scope": source.scope, "capture_seconds": captureSeconds]
                if item.infer {
                    let summary = Summarize(captureSource: { _,_ in source })
                    summary.start(displayID: CGMainDisplayID(), target: target)
                    while summary.isBusy, Date().timeIntervalSince(began) < 60 { try await Task.sleep(for: .milliseconds(40)) }
                    checks[item.name + "-summary"] = summary.phase == .complete && !summary.text.isEmpty
                    checks[item.name + "-summary-facts"] = (item.summaryIncludes ?? []).allSatisfy { summary.text.localizedCaseInsensitiveContains($0) }
                    if let expected = item.expectedSource {
                        checks[item.name + "-verified-source"] = summary.sourceInfo?.kind.rawValue == expected
                    }
                    if item.checkPresentation == true {
                        checks[item.name + "-emphasis"] = summary.text.contains("**")
                        let opening = summary.text.lowercased().replacingOccurrences(of: "**", with: "")
                        checks[item.name + "-direct-opening"] = !["in the available", "based on the provided", "the screenshot shows", "this summary"].contains { opening.hasPrefix($0) }
                        let sections = summary.text.components(separatedBy: "\n---\n")
                        let overviewFirst = summary.text.hasPrefix("**TL;DR:**") && sections.count == 2
                            && sections.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        let brief = summary.text.split(whereSeparator: \.isWhitespace).count <= 60
                            && !summary.text.contains("TL;DR") && sections.count == 1
                        checks[item.name + "-tldr-layout"] = overviewFirst || brief
                        try await Task.sleep(for: .milliseconds(500))
                        if let host = summary.fixtureWindow?.contentView {
                            _ = try await SidekickPolishLab.capture(host, name: item.name + "-summary", directory: root)
                        }
                    }
                    result["summary"] = summary.text; result["error"] = summary.error ?? ""
                    result["source_label"] = summary.sourceLabel
                    result["source_kind"] = summary.sourceInfo?.kind.rawValue ?? ""
                    result["source_truncated"] = summary.sourceInfo?.truncated ?? false
                    summary.dismiss()
                }
                results.append(result)
            } catch {
                checks[item.name + "-capture"] = false
                results.append(["name": item.name, "error": String(describing: error)])
            }
            try JSONSerialization.data(withJSONObject: ["checks": checks,"results":results], options: [.prettyPrinted,.sortedKeys])
                .write(to: root.appendingPathComponent("summary-audit.json"), options: .atomic)
        }
        guard checks.values.allSatisfy({$0}) else { throw Failure.checks }
        return checks
    }
    enum Failure: Error { case notAuthorized, missingApp, missingWindow, summary, checks }
}
#endif
