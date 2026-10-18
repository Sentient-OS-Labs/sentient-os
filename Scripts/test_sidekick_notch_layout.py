#!/usr/bin/env python3
"""Measure production notch message layout against its real native Markdown renderer.

No app/window/provider launch. TextKit measurement and the bounded layout/cache are real.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"

FIXTURE = r'''
import AppKit

@main enum NotchLayoutTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { fatalError("FAIL: " + label) }
        checks += 1
    }
    static func size(_ text: String, width: CGFloat = 520, height: CGFloat = 286) -> CGSize {
        SidekickNotchMessageLayout(markdown: text, maximumSize: CGSize(width: width, height: height),
            cameraHeight: 37, outerTopPad: 0, outerBottomPad: 4, horizontalPad: 18).size
    }
    static func nativeParagraph(_ text: String, width: CGFloat, heading: Int? = nil) -> CGFloat {
        let document = SidekickMarkdownDocument(markdown: text)
        guard case .text(let fragment, _) = document.blocks[0] else { fatalError("expected text fixture") }
        let style = SidekickSelectableMarkdown.Style(compact: true, heading: heading,
            code: false, bold: false, alignment: .left)
        let view = SidekickMarkdownTextView()
        view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textStorage?.setAttributedString(SidekickSelectableMarkdown.styled(fragment.attributed, style: style))
        return SidekickSelectableMarkdown.measuredSize(view, proposedWidth: width, style: style, wrapping: true)!.height
    }
    static func main() {
        let fixture = "You're free **2:30–4:00 PM tomorrow**. That gives you a quiet 90-minute block after your design review.\n\nI can help protect that time when you're ready."
        let short = size(fixture)
        check(short.width == 520 && short.height >= 190 && short.height < 250,
              "actual two-paragraph preview sheds oversized empty reading space")
        check((190...200).contains(size("Done.").height), "single native line reserves compact chrome without growing to maximum")
        check(size("").height == 190, "empty response retains minimum stable controls")
        check(size(fixture) == short, "cached repeated hit testing returns identical geometry")
        check(size(fixture, width: 360).height >= short.height, "narrower display never undermeasures wrapping")
        check(size(fixture).height == short.height, "width-specific cache does not corrupt original measurement")

        let plain = "A compact response with **important details**, café, and a link to [the source](https://example.com)."
        let native = nativeParagraph(plain, width: 484)
        // Actual camera/header/footer/spacing/padding together occupy177 points. The native
        // renderer's independent NSTextView measurement must fit the layout's text allowance.
        check(size(plain).height >= 177 + native, "native formatted paragraph fits without clipping")
        check(size(plain).height <= 179 + native, "paragraph measurement does not introduce excess dead space")
        let heading = "# A small heading"
        check(size(heading).height >= 177 + 4 + nativeParagraph(heading, width: 484, heading: 1),
              "heading uses shared compact font and heading inset")
        let list = "- A sufficiently long list item with its own marker that wraps around a narrow message preview without clipping the text beside it."
        check(size(list, width: 360).height >= size(list).height, "list indentation participates in wrapping")
        let quote = "> > Nested quotation that keeps its visible left inset when calculating the available message width."
        check(size(quote, width: 360).height > 190, "nested quote is measured within its decoration inset")

        check(size(String(repeating: "x", count: 1_001)).height == 286, "long source bypasses parser and keeps bounded maximum")
        check(size(String(repeating: "😀", count: 501)).height == 286, "Unicode parse bound is conservative")
        check(size("a" + String(repeating: "\u{301}", count: 5_000)).height == 286,
              "pathological combining grapheme cannot bypass parse budget")
        check(size("```swift\nprint(1)\n```").height == 286, "code scroll/header chrome retains maximum")
        check(size("| A | B |\n|---|---|\n| one | two |").height == 286, "table grid keeps bounded reading surface")
        check(size(String(repeating: "A paragraph.\n\n", count: 50)).height == 286,
              "many short blocks cannot exceed the maximum")
        check(size(fixture, height: 160).height == 160, "available screen height caps measured preview")
        check(size("Done.", height: 120).height == 120, "small displays take precedence over preferred minimum")
        check(size("Changed.").height < size(fixture).height, "message content changes invalidate cached height")
        print("PASS: \(checks) Sidekick notch layout checks; fixture height \(short.height)pt")
    }
}
'''


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="sentient-notch-layout-test-") as temporary:
        directory = Path(temporary)
        fixture = directory / "NotchLayoutTests.swift"
        fixture.write_text(FIXTURE)
        executable = directory / "notch-layout-tests"
        subprocess.run([
            "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
            "-enable-upcoming-feature", "NonisolatedNonsendingByDefault", "-warnings-as-errors", "-parse-as-library",
            str(APP / "Views/Sidekick/SidekickMarkdownDocument.swift"),
            str(APP / "Views/Sidekick/SidekickMarkdown.swift"),
            str(APP / "Notch Magic/SidekickNotchMessageLayout.swift"), str(fixture),
            "-o", str(executable),
        ], check=True, timeout=60)
        subprocess.run([str(executable)], check=True, timeout=20)


if __name__ == "__main__":
    main()
