// Opt-in live acceptance of the production Swift clients using only synthetic text and pixels.
// The test installation identity is isolated from the user's Keychain and reused across retries.
import AppKit
import Foundation

enum ScreenRelay {
    static var url: URL? { URL(string: CommandLine.arguments[2]) }
    static func identity() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("live-test-installation.txt"), encoding: .utf8)
    }
}

@main enum ScreenActionsLive {
    static func main() async {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var records: [[String: Any]] = []
        do {
            let examples = [
                ("grammar", "We was excited to recieve the update.", "We were excited to receive the update."),
                ("unchanged", "The meeting starts at 3 PM on Friday.", "The meeting starts at 3 PM on Friday."),
                ("whitespace", "  Please review teh draft.\n\nThe figures is final.  ", "  Please review the draft.\n\nThe figures are final.  "),
            ]
            for (name, original, expected) in examples {
                let start = Date()
                let result = try await ProofreadInference.correct(original)
                let passed = result == expected
                records.append(["case": name, "passed": passed, "text": result, "elapsed_seconds": Date().timeIntervalSince(start)])
                print("Proofread \(name): \(passed ? "PASS" : "FAIL")")
                guard passed else { throw Check.failed }
            }
            let image = makeScreen()
            try image.write(to: root.appendingPathComponent("swift-client-screen.jpg"))
            let start = Date()
            var deliveries = 0
            let summary = try await SummarizeInference.stream(image: image, preference: "") { _ in deliveries += 1 }
            let lower = summary.lowercased()
            let passed = lower.contains("friday") && (lower.contains("3") || lower.contains("15:00")) && (lower.contains("two") || lower.contains("2"))
            records.append(["case": "screen_summary", "passed": passed, "text": summary, "deliveries": deliveries, "elapsed_seconds": Date().timeIntervalSince(start)])
            guard passed else { throw Check.failed }
            try save(root, passed: true, records: records)
            print("PASS: four live requests through production Swift clients")
            exit(0)
        } catch {
            try? save(root, passed: false, records: records)
            print("Live acceptance failed: \(String(describing: type(of: error)))")
            exit(1)
        }
    }
    enum Check: Error { case failed }
    static func save(_ root: URL, passed: Bool, records: [[String: Any]]) throws {
        try JSONSerialization.data(withJSONObject: ["passed": passed, "synthetic_inputs_only": true, "results": records], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("swift-client-live-checks.json"), options: .atomic)
    }
    static func makeScreen() -> Data {
        let image = NSImage(size: NSSize(width: 1200, height: 800))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 800).fill()
        let lines: [(String, CGFloat, CGFloat)] = [
            ("SYNTHETIC TEST DOCUMENT", 700, 22), ("Launch review", 620, 44),
            ("Deadline: Friday, 3 PM", 490, 32), ("Design: approved", 395, 32),
            ("QA: 2 issues remain", 300, 32), ("Next step: review fixes before launch.", 205, 32),
        ]
        for (text, y, size) in lines {
            (text as NSString).draw(at: NSPoint(x: 80, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
    }
}
