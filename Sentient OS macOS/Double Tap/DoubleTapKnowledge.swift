// Readiness for a knowledge base copied from another Mac. Never writes analysis milestones.
import Foundation

enum DoubleTapKnowledge {
    /// Stop at the first readable, nonempty Markdown note that can fit in a draft. An empty
    /// directory, writing samples alone, hidden files and symlinks are not personal knowledge.
    /// Check on demand so adding or removing an AirDropped vault takes effect immediately.
    static func hasContent(in directory: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0 else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(root.path + "/") else { continue }
            let relative = String(path.dropFirst(root.path.count + 1))
            guard relative != WritingStyle.fileName,
                  size + relative.utf8.count + 5 <= DoubleTapInference.vaultByteCeiling,
                  let content = try? String(contentsOf: url, encoding: .utf8),
                  content.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else { continue }
            return true
        }
        return false
    }
}
