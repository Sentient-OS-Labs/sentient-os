#!/usr/bin/env python3
"""Compile the production overview solver and check geometry across measured card sizes.

No implementation copies, AppKit, app launch, provider, UI automation or real preferences.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sentient OS macOS/Views/Sidekick/SidekickOverviewLayout.swift"
FIXTURE = r'''
import Foundation
import CoreGraphics

@main struct OverviewLayoutChecks {
    static var checks = 0
    static var configurations = 0
    static let tolerance: CGFloat = 0.00001
    static func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        precondition(condition(), description); checks += 1
    }
    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < tolerance }
    /// Cards stretch to their row's slot, so the slot is the rendered frame.
    static func frame(_ layout: SidekickOverviewLayout, index: Int) -> CGRect {
        let point = layout.positions[index]
        return CGRect(x: point.x - layout.cardWidth / 2, y: point.y - layout.slotHeights[index] / 2,
                      width: layout.cardWidth, height: layout.slotHeights[index])
    }
    static func inspect(size: CGSize, top: CGFloat, bottom: CGFloat, heights: [CGFloat], requestedPage: Int) {
        configurations += 1
        let layout = SidekickOverviewLayout(size: size, top: top, bottom: bottom, heights: heights, requestedPage: requestedPage)
        check(layout.columns >= 1 && layout.columns <= (size.width >= 1180 ? 3 : 2), "column count exceeds responsive limit")
        check(layout.cardWidth <= 400 && layout.cardWidth >= 240, "readable width bounds changed")
        check(layout.rows >= 1 && layout.rows <= 2 && layout.capacity > 0, "invalid capacity")
        check(layout.pageCount >= 1 && (0..<layout.pageCount).contains(layout.page), "page out of range")
        check(layout.visibleRange.lowerBound >= 0 && layout.visibleRange.upperBound <= heights.count,
              "visible card index out of range")
        check(layout.positions.count == heights.count, "positions lost source card identity")
        check(layout.region.origin.x.isFinite && layout.region.origin.y.isFinite
                && layout.region.width.isFinite && layout.region.height.isFinite && layout.region.height >= 0,
              "invalid safe region")
        check(layout.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "nonfinite card position")
        check(layout.rowHeight >= (heights.max() ?? 0), "measured card height was compressed")
        check(layout.slotHeights.count == heights.count, "slot heights lost source card identity")
        check(zip(layout.slotHeights, heights).allSatisfy { $0 >= $1 && $0 <= layout.rowHeight },
              "a slot compressed its card or exceeded the deck's tallest card")
        let visible = Array(layout.visibleRange)
        check(Set(visible).count == visible.count, "same card occurs twice on one page")
        let frames = visible.map { frame(layout, index: $0) }
        let available = max(0, layout.region.height - SidekickOverviewLayout.pagerHeight)
        let enoughRoom = available + tolerance >= (heights.max() ?? 0)
        for card in frames {
            check(card.minX >= 38 - tolerance && card.maxX <= size.width - 38 + tolerance,
                  "card escaped horizontal safe inset")
            check(card.minY >= top - tolerance, "card overlaps header")
            if enoughRoom {
                check(card.maxY <= layout.region.maxY - SidekickOverviewLayout.pagerHeight + tolerance,
                      "card overlaps pager/composer despite room for a full row")
            }
        }
        // Each row is as tall as its own tallest card: its cards share both edges, and
        // consecutive rows sit exactly 24pt apart, matching the column gutter.
        for left in frames.indices {
            for right in frames.indices where right > left {
                let a = frames[left], b = frames[right]
                if near(a.minY, b.minY) {
                    check(near(a.maxY, b.maxY), "same-row cards do not share a bottom edge")
                    let horizontalGap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                    check(horizontalGap + tolerance >= 24, "same-row cards overlap or violate 24pt spacing")
                    if right == left + 1 { check(near(horizontalGap, 24), "adjacent columns do not have exact 24pt gap") }
                } else {
                    let verticalGap = max(a.minY, b.minY) - min(a.maxY, b.maxY)
                    check(verticalGap + tolerance >= 24, "rows overlap or violate minimum 24pt spacing")
                    if visible[right] - visible[left] == layout.columns {
                        check(near(verticalGap, 24), "consecutive rows do not have exact 24pt gap")
                    }
                }
            }
        }
        if !frames.isEmpty {
            let lastTop = frames.map(\.minY).max()!
            let finalRow = frames.filter { near($0.minY, lastTop) }
            let unionMin = finalRow.map(\.minX).min()!, unionMax = finalRow.map(\.maxX).max()!
            check(near((unionMin + unionMax) / 2, size.width / 2), "short final row is not centered")
        }
    }
    static func main() {
        let sizes = [CGSize(width: 840, height: 680), CGSize(width: 1100, height: 820), CGSize(width: 1440, height: 900)]
        let mixed: [CGFloat] = [160, 245, 182, 230, 175, 206]
        for size in sizes {
            let top: CGFloat = 164, bottom = size.height - 202
            for count in 0...6 {
                let profiles = [Array(repeating: CGFloat(160), count: count), Array(repeating: CGFloat(200), count: count),
                                Array(repeating: CGFloat(245), count: count), Array(mixed.prefix(count))]
                let referenceWidth = SidekickOverviewLayout.width(for: size, count: count)
                for heights in profiles {
                    let initial = SidekickOverviewLayout(size: size, top: top, bottom: bottom, heights: heights, requestedPage: 0)
                    check(initial.columns == min(max(count, 1), size.width >= 1180 ? 3 : 2), "responsive column count incorrect")
                    check(initial.cardWidth == referenceWidth, "fitting taller cards shrank card width")
                    var visited: [Int] = []
                    for page in 0..<initial.pageCount {
                        inspect(size: size, top: top, bottom: bottom, heights: heights, requestedPage: page)
                        let current = SidekickOverviewLayout(size: size, top: top, bottom: bottom, heights: heights, requestedPage: page)
                        visited += Array(current.visibleRange)
                    }
                    check(visited == Array(0..<count), "pagination missed, duplicated or reordered cards")
                    for invalid in [Int.min, -1, initial.pageCount, Int.max] {
                        inspect(size: size, top: top, bottom: bottom, heights: heights, requestedPage: invalid)
                        let clamped = SidekickOverviewLayout(size: size, top: top, bottom: bottom, heights: heights, requestedPage: invalid)
                        check(clamped.page == (invalid < 0 ? 0 : initial.pageCount - 1), "invalid page was not clamped")
                    }
                }
            }
        }
        let size = CGSize(width: 1100, height: 820)
        let short = SidekickOverviewLayout(size: size, top: 164, bottom: 618, heights: Array(repeating: 160, count: 6), requestedPage: 2)
        let tall = SidekickOverviewLayout(size: size, top: 164, bottom: 618, heights: Array(repeating: 245, count: 6), requestedPage: 2)
        check(short.capacity == 4 && tall.capacity == 2, "actual measured heights did not change available row capacity")
        check(short.page == 1 && tall.page == 2, "capacity change did not clamp/retain requested page correctly")
        check(short.cardWidth == tall.cardWidth && tall.rowHeight == 245, "readable cards were scaled down to fit")
        // A tall card on a later page must not stretch the rows of the page in view.
        let paged = SidekickOverviewLayout(size: size, top: 164, bottom: 618,
                                           heights: [150, 170, 160, 150, 185, 140], requestedPage: 0)
        check(paged.capacity == 4 && paged.slotHeights == [170, 170, 160, 160, 185, 185], "rows did not size to their own cards")
        check(near(paged.positions[2].y - paged.slotHeights[2] / 2 - (paged.positions[0].y + paged.slotHeights[0] / 2), 24),
              "a later page's tall card widened the visible row gap")
        let narrow = SidekickOverviewLayout(size: CGSize(width: 840, height: 680), top: 164, bottom: 478,
                                           heights: Array(repeating: 180, count: 6), requestedPage: 2)
        let wide = SidekickOverviewLayout(size: CGSize(width: 1440, height: 900), top: 164, bottom: 698,
                                         heights: Array(repeating: 180, count: 6), requestedPage: narrow.page)
        check(narrow.columns == 2 && wide.columns == 3, "resize did not switch two columns to three")
        check(wide.page == 0 && wide.visibleRange == 0..<6, "resize left a stale inaccessible page")
        for count in 0...6 {
            for bottom: CGFloat in [164, 0] {
                inspect(size: size, top: 164, bottom: bottom, heights: Array(mixed.prefix(count)), requestedPage: Int.max)
                let emptyRoom = SidekickOverviewLayout(size: size, top: 164, bottom: bottom,
                    heights: Array(mixed.prefix(count)), requestedPage: Int.max)
                check(emptyRoom.region.height == 0, "inverted/zero-height region did not clamp safely")
            }
        }
        print("PASS: \(configurations) overview geometry configurations; \(checks) assertions")
        print("Covered 0–6 cards, three window sizes, 160–245pt measured heights, equal-height rows, exact 24pt spacing, centered final rows, pagination, resize, invalid pages and zero-height regions.")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient-overview-layout-") as temporary:
    directory = Path(temporary)
    fixture = directory / "OverviewChecks.swift"
    fixture.write_text(FIXTURE)
    binary = directory / "overview-checks"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
                    "-strict-concurrency=complete", "-enable-upcoming-feature", "MemberImportVisibility", "-warnings-as-errors", "-parse-as-library",
                    str(SOURCE), str(fixture), "-o", str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=30)
