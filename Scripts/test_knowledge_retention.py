#!/usr/bin/env python3
"""Regression checks for retained Knowledge sky using the complete production model.

Loads a disposable real vault through production tree/graph/physics code. Only decorative
renderer dust, logging, test-root selection and the irrelevant random seed helper are inert.
No application/window/provider launch or production preferences/files are accessed.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"

SUPPORT = r'''
import Foundation

enum VaultGenerator {
    static var vaultRoot: URL { URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("vault") }
}
enum WritingStyle { static let fileName = ".fixture-writing-style.md" }
enum SkyRenderer { static func makeDust() -> [Int] { [] } }
func Log(_ text: String) { }
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}
'''

FIXTURE = r'''
import Foundation
@main @MainActor enum KnowledgeRetentionTests {
    static var checks = 0
    static let viewport = CGSize(width: 1000, height: 720)
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { fatalError("FAIL: " + label) }
        checks += 1
    }
    static func seed() throws -> KnowledgeVault {
        let root = VaultGenerator.vaultRoot
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        try "# Overview\n\nA fixture with [[Alpha]] and [[Beta]].".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "# Alpha\n\nA project connected to [[Beta]].".write(to: root.appendingPathComponent("Projects/Alpha.md"), atomically: true, encoding: .utf8)
        try "# Beta\n\nA second project.".write(to: root.appendingPathComponent("Projects/Beta.md"), atomically: true, encoding: .utf8)
        return KnowledgeVault.load()!
    }
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let vault = try seed()
        let model = NightSkyModel()
        await model.load(vault: vault)
        check(model.graph?.nodes.count == 3 && model.graph?.edges.count == 3, "real fixture vault builds its notes and wikilinks")
        model.sim?.settle()
        model.tick(now: 100, size: viewport)
        let selected = model.graph!.nodes.firstIndex { !$0.isRoot }!
        let selectedURL = model.graph!.nodes[selected].url
        model.highlight(selectedURL)
        model.updateHover(model.toScreen(model.sim!.pos[selected], size: viewport), size: viewport)
        model.tick(now: 200, size: viewport)
        check(model.hoverInfo != nil && model.highlightIndex != nil, "fixture establishes hover and reader highlight")
        check(!model.pulses.isEmpty, "fixture establishes an active connection pulse")
        model.camera.pan = CGPoint(x: 63, y: -42); model.camera.zoom = 1.7
        let camera = model.camera
        let moved = directory.appendingPathComponent("moved-vault")
        try FileManager.default.moveItem(at: vault.root, to: moved)
        check(KnowledgeVault.load() == nil, "production vault reader reports moved folder as absent")
        await model.load(vault: KnowledgeVault.load())
        check(model.graph == nil && model.sim == nil && model.glow.isEmpty, "authoritative absent vault clears graph and simulation")
        check(model.hoverInfo == nil && model.hoverIndex == nil && model.focusIndex == nil && model.focusNeighbors.isEmpty && model.focusBlend == 0,
              "missing vault releases all hover and focus state")
        check(model.highlightIndex == nil && model.pulses.isEmpty, "missing vault clears highlight and transient pulses")
        check(model.nodeURL(selected) == nil && model.hitTest(.zero, size: viewport) == nil,
              "deleted notes cannot remain clickable")
        check(model.hoverCardRect(in: viewport) == nil && model.sunOverlay(size: viewport) == nil,
              "deleted vault cannot leave stale hover card or sun overlay")
        check(model.camera.pan == camera.pan && model.camera.zoom == camera.zoom,
              "clearing unavailable data does not discard retained camera preferences")

        // Pending reader highlights and drag ownership must not leak into a replacement sky.
        model.highlight(selectedURL)
        await model.load(vault: nil)
        try FileManager.default.moveItem(at: moved, to: vault.root)
        await model.load(vault: KnowledgeVault.load())
        check(model.highlightIndex == nil, "pending highlight from absent vault is discarded")
        model.beginDrag(selected)
        await model.load(vault: nil)
        await model.load(vault: KnowledgeVault.load())
        model.sim?.settle()
        model.updateHover(model.toScreen(model.sim!.pos[selected], size: viewport), size: viewport)
        check(model.hoverInfo != nil, "nil reset releases drag flag so restored sky accepts hover")

        // Fresh timing after nil must match a new model, not perform a hidden-time catch-up.
        await model.load(vault: nil)
        await model.load(vault: KnowledgeVault.load())
        let fresh = NightSkyModel()
        await fresh.load(vault: KnowledgeVault.load())
        model.tick(now: 500, size: viewport); fresh.tick(now: 500, size: viewport)
        check(model.sim?.pos == fresh.sim?.pos, "nil reset clears old frame clock")
        model.sim?.settle(); model.tick(now: 501, size: viewport)
        check(model.pulses.isEmpty, "restored sky does not reuse expired pulse deadline")

        let retainedNodes = model.graph!.nodes.map(\.url)
        let cancelled = Task { await model.load(vault: nil) }
        cancelled.cancel(); await cancelled.value
        check(model.graph?.nodes.map(\.url) == retainedNodes, "cancelled nil load cannot erase current valid sky")
        let preview = NightSkyModel.preview(hovering: 1)
        let previewNodes = preview.graph!.nodes.map(\.url)
        await preview.load(vault: nil)
        check(preview.graph?.nodes.map(\.url) == previewNodes && preview.sim != nil,
              "explicit preview factory preserves its mock galaxy without a vault")
        await preview.load(vault: KnowledgeVault.load())
        await preview.load(vault: nil)
        check(preview.graph == nil && preview.sim == nil, "preview exemption ends after real vault data commits")

        // Start an older real graph refresh, then publish an authoritative absent snapshot.
        // The detached reader may finish before or after the second load; both orderings
        // must leave the newer nil snapshot authoritative, without fake provider callbacks.
        for number in 0..<30 {
            try String(repeating: "A fixture body linked to [[Alpha]].\n", count: 200)
                .write(to: vault.root.appendingPathComponent("Extra-\(number).md"), atomically: true, encoding: .utf8)
        }
        let olderVault = KnowledgeVault.load()!
        var olderStarted = false
        let obsolete = Task { olderStarted = true; await model.load(vault: olderVault) }
        while !olderStarted { await Task.yield() }
        try FileManager.default.moveItem(at: vault.root, to: moved)
        await model.load(vault: KnowledgeVault.load())
        check(model.graph == nil, "newer missing-vault snapshot clears during refresh")
        await obsolete.value
        check(model.graph == nil && model.sim == nil && model.nodeURL(0) == nil,
              "older refresh cannot supersede newer missing-vault snapshot")
        print("PASS: \(checks) Knowledge retention checks")
    }
}
'''


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="sentient-knowledge-retention-") as temporary:
        directory = Path(temporary)
        support = directory / "Support.swift"
        fixture = directory / "KnowledgeRetentionTests.swift"
        support.write_text(SUPPORT)
        fixture.write_text(FIXTURE)
        binary = directory / "checks"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
            "-enable-upcoming-feature", "NonisolatedNonsendingByDefault", "-parse-as-library",
            str(APP / "Views/Knowledge/VaultTree.swift"), str(APP / "Views/Knowledge/Graph/SkyGraph.swift"),
            str(APP / "Views/Knowledge/Graph/SkySimulation.swift"), str(APP / "Views/Knowledge/Graph/NightSkyModel.swift"),
            str(support), str(fixture), "-o", str(binary),
        ], check=True, timeout=60)
        subprocess.run([str(binary), str(directory)], check=True, timeout=30)


if __name__ == "__main__":
    main()
