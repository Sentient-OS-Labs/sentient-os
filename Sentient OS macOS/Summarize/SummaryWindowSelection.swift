import Foundation
import CoreGraphics

/// WindowServer abbreviates some Chromium titles; AX retains the complete title.
/// Geometry alone is ambiguous when several browser windows are maximized.
enum SummaryWindowSelection {
    struct Candidate {
        let id: CGWindowID
        let pid: pid_t
        let title: String?
        let frame: CGRect
        var layer: Int = 0
    }

    static func choose(_ candidates: [Candidate], pid: pid_t, title: String?, frame: CGRect?, appName: String?) -> CGWindowID? {
        let owned = candidates.filter { $0.pid == pid && $0.layer == 0 }
        let wanted = normalized(title, appName: appName)
        let geometry = owned.filter { item in
            guard let frame else { return false }
            return abs(item.frame.minX - frame.minX) < 2 && abs(item.frame.minY - frame.minY) < 2
                && abs(item.frame.width - frame.width) < 2 && abs(item.frame.height - frame.height) < 2
        }
        func unique(_ items: [Candidate]) -> CGWindowID? { items.count == 1 ? items[0].id : nil }
        func exact(_ item: Candidate) -> Bool {
            !wanted.isEmpty && normalized(item.title, appName: appName) == wanted
        }
        if let id = unique(geometry.filter(exact)) { return id }
        if !wanted.isEmpty, let id = unique(geometry.filter {
            abbreviated(normalized($0.title, appName: appName), matches: wanted)
        }) { return id }
        // A window may have moved since the request. Only its full, unique title
        // can identify it without matching geometry; never choose an arbitrary window.
        if let id = unique(owned.filter(exact)) { return id }
        if geometry.count == 1, let item = geometry.first,
           wanted.isEmpty || normalized(item.title, appName: appName).isEmpty { return item.id }
        return nil
    }

    private static func normalized(_ title: String?, appName: String?) -> String {
        var result = (title ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let appName, !appName.isEmpty {
            for separator in [" - ", " – ", " — "] where result.hasSuffix(separator + appName) {
                result.removeLast(separator.count + appName.count)
                break
            }
        }
        return result
    }

    private static func abbreviated(_ shortened: String, matches full: String) -> Bool {
        for separator in ["…", "..."] {
            let parts = shortened.components(separatedBy: separator)
            guard parts.count == 2, let first = parts.first, let last = parts.last,
                  first.count >= 8, last.count >= 8, full.count > first.count + last.count else { continue }
            if full.hasPrefix(first) && full.hasSuffix(last) { return true }
        }
        return false
    }
}
