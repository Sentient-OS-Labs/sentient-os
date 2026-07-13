//
//  NightSkyView.swift
//  Sentient OS macOS
//
//  The Night Sky — the Knowledge window's graph view (user-facing name: "Constellation View";
//  it's the window's DEFAULT face). Your knowledge base as a private galaxy:
//  notes are twinkling stars sized by connection count, top-level folders are labeled
//  constellations, wikilinks are threads that ignite on hover, and the root README is the sun.
//  TimelineView(.animation) + Canvas render (SkyRenderer); an AppKit event catcher gives real
//  pan (two-finger scroll) / zoom (pinch, mouse wheel, ⌘-scroll) / star dragging / hover / click
//  (→ open the note in the reader) / Esc (→ back to the reader).
//
//  Data: SkyGraph · physics: SkySimulation · brain: NightSkyModel · drawing: SkyRenderer.
//  Doc: Documentation/Knowledge Viewer.md
//

import SwiftUI
import AppKit

struct NightSkyView: View {
    let vault: KnowledgeVault?
    var vaultLoaded = true       // false only while KnowledgeView's vault scan is still in flight
    @ObservedObject var model: NightSkyModel
    var onOpen: (URL) -> Void
    var onExit: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let graph = model.graph, !graph.nodes.isEmpty {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tl in
                        ZStack {
                            Canvas { ctx, size in
                                let t = tl.date.timeIntervalSinceReferenceDate
                                model.tick(now: t, size: size)
                                SkyRenderer.draw(ctx, size: size, model: model, t: t)
                            }
                            // The sun IS the brand mark: the notch's SpinningLogo, slow, riding
                            // the root star's screen position (the canvas draws its light bed).
                            if let sun = model.sunOverlay(size: geo.size) {
                                SpinningLogo(size: sun.diameter, fast: false)
                                    .position(sun.center)
                                    .opacity(sun.opacity)
                            }
                        }
                    }
                    SkyEventCatcher(model: model, onOpen: onOpen, onExit: onExit)
                    hud(graph: graph)
                    if model.hoverInfo != nil, let card = model.hoverCardRect(in: geo.size) {
                        SkyHoverCard(info: model.hoverInfo!)
                            .position(x: card.midX, y: card.midY)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                } else if model.graph != nil || (vaultLoaded && vault == nil) {
                    emptyState
                } else {
                    Color.clear      // vault scan / graph build in flight — the entrance covers the gap
                }
            }
            .animation(.easeOut(duration: 0.16), value: model.hoverInfo)
        }
        .background(Theme.bg)
        // Reruns on every sky entry (silent refresh) AND when the vault first arrives — with the
        // Constellation View as the window's default, this view mounts before the async vault
        // scan finishes, so the graph must build the moment the vault lands.
        .task(id: vault?.root) { await model.load(vault: vault) }
    }

    // MARK: HUD (whispers — none of it intercepts the cursor)

    private func hud(graph: SkyGraph) -> some View {
        ZStack {
            Color.clear
            VStack(alignment: .leading, spacing: 5) {
                MonoCaps("Constellation View", size: 9, tracking: 3, color: Theme.Ink.label)
                Text("Your life, from above.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.Ink.statusInk.opacity(0.85))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 14).padding(.leading, 22)

            MonoCaps("\(graph.nodes.count) notes · \(graph.edges.count) threads · \(graph.domains.count) constellations",
                     size: 9.5, tracking: 2, color: Theme.Ink.label)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.bottom, 16).padding(.leading, 22)

            HStack(spacing: 8) {
                Image(systemName: "shield").font(.system(size: 11)).foregroundStyle(Theme.Ink.label)
                Text("Private by design.")
                    .font(.system(size: 12)).foregroundStyle(Theme.Ink.label)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 16)
        }
        .allowsHitTesting(false)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Orb(size: 92)
            Text("Your sky is still forming.")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.Ink.statusInk)
            Text("Once Sentient has read your life, every note becomes a star.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The door (shared by both sides: "Constellation View" in the reader, "Reader" in the sky)

/// The mode switch in the titlebar (both KnowledgeView toolbars mount one via SkyDoorToolbarItem).
/// A native toolbar button — same font and glass as its Edit / Reveal in Finder neighbours —
/// wearing the SkyDoorRim so the other mode is discoverable. ⌘⇧G fires whichever door is mounted.
struct SkyDoor: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
        }
        .labelStyle(.titleAndIcon)
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .overlay { SkyDoorRim() }
    }
}

/// The slow-moving gradient rim both mode doors wear — field-tested: behind plain glass, users
/// never found the reader at all. Theme.magicGlow (teal → cyan → blue → indigo → purple), muted
/// to a whisper, circles the capsule once every 8s: a soft bloom under a crisp 1pt edge.
/// Cosmetic only — it never intercepts the cursor.
private struct SkyDoorRim: View {
    private static let period: Double = 8.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: Self.period) / Self.period) * 360.0
            let rim = AngularGradient(colors: Theme.magicGlow, center: .center, angle: .degrees(angle))
            ZStack {
                Capsule(style: .continuous).strokeBorder(rim, lineWidth: 2.5)
                    .blur(radius: 3).opacity(0.45)
                Capsule(style: .continuous).strokeBorder(rim, lineWidth: 1).opacity(0.8)
            }
            .saturation(0.65)
        }
        .allowsHitTesting(false)
    }
}

/// The door's toolbar seat.
struct SkyDoorToolbarItem: ToolbarContent {
    let icon: String
    let label: String
    let help: String
    var placement: ToolbarItemPlacement = .principal   // sky: top-center · reader: .navigation (top-left)
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: placement) {
            SkyDoor(icon: icon, label: label, action: action).help(help)
        }
    }
}

// MARK: - The hover card

private struct SkyHoverCard: View {
    let info: SkyHoverInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MonoCaps(info.domainName, size: 8.5, tracking: 2, color: Theme.Ink.label)
            Text(info.title)
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(Theme.Ink.statusInk)
                .lineLimit(2)
            if !info.preview.isEmpty {
                Text(info.preview)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Ink.body)
                    .lineLimit(2)
            }
            if info.recentlyChanged {
                MonoCaps("Changed last night", size: 7.5, tracking: 1.5, color: Theme.dawnCyan)
            }
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        .background(Theme.Ink.cardBG.opacity(0.94), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
        .allowsHitTesting(false)
    }
}

// MARK: - Event catcher (real AppKit events: scroll, pinch, drag, hover, click, Esc)

private struct SkyEventCatcher: NSViewRepresentable {
    let model: NightSkyModel
    let onOpen: (URL) -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> SkyEventNSView { SkyEventNSView() }

    func updateNSView(_ v: SkyEventNSView, context: Context) {
        v.model = model
        v.onOpen = onOpen
        v.onExit = onExit
    }
}

private final class SkyEventNSView: NSView {
    weak var model: NightSkyModel?
    var onOpen: ((URL) -> Void)?
    var onExit: (() -> Void)?

    private enum DragMode { case none, star(Int), pan }
    private var dragMode: DragMode = .none
    private var downPoint: CGPoint = .zero
    private var lastDragPoint: CGPoint = .zero
    private var moved = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }           // match SwiftUI/Canvas coordinates

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window else { return }
            w.makeFirstResponder(self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    // MARK: Hover

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        model?.updateHover(p, size: bounds.size)
        (model?.hoverIndex != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        model?.clearHover()
        NSCursor.arrow.set()
    }

    // MARK: Click / drag (a still click opens the note; a drag moves a star or pans the sky)

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p
        lastDragPoint = p
        moved = false
        if let i = model?.hitTest(p, size: bounds.size) {
            dragMode = .star(i)
            model?.beginDrag(i)
        } else {
            dragMode = .pan
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if (p - downPoint).length > 3 { moved = true }
        switch dragMode {
        case .star:
            model?.dragStar(to: p, size: bounds.size)
        case .pan:
            model?.panBy(dx: p.x - lastDragPoint.x, dy: p.y - lastDragPoint.y)
        case .none:
            break
        }
        lastDragPoint = p
    }

    override func mouseUp(with event: NSEvent) {
        if case .star(let i) = dragMode {
            model?.endDrag()
            if !moved, let url = model?.nodeURL(i) { onOpen?(url) }
        }
        dragMode = .none
    }

    // MARK: Scroll + pinch (trackpad pans, wheel/⌘-scroll/pinch zoom — Figma manners)

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            model?.panBy(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        } else {
            let scale = event.hasPreciseScrollingDeltas ? 0.01 : 0.05
            model?.zoom(by: exp(event.scrollingDeltaY * scale), at: p, size: bounds.size)
        }
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        model?.zoom(by: 1 + event.magnification, at: p, size: bounds.size)
    }

    // MARK: Keys (Esc returns to the reader; everything else is quietly ignored — no beeps)

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onExit?() }
    }
}

// MARK: - Previews (SkyRenderer's eyes — the mock galaxy is seeded, so renders are stable)

#Preview("Night Sky — settled") {
    NightSkyView(vault: nil, model: .preview(), onOpen: { _ in }, onExit: {})
        .frame(width: 1280, height: 800)
        .preferredColorScheme(.dark)
}

#Preview("Night Sky — ignited (hover)") {
    NightSkyView(vault: nil, model: .preview(hovering: 22), onOpen: { _ in }, onExit: {})
        .frame(width: 1280, height: 800)
        .preferredColorScheme(.dark)
}

#Preview("Night Sky — hover card") {
    ZStack {
        Color.black
        SkyHoverCard(info: SkyHoverInfo(url: URL(fileURLWithPath: "/mock/a.md"),
                                        title: "Sentient OS – Launch Timeline",
                                        domainName: "Sentient OS",
                                        preview: "Beta invite waves, the Reddit playbook, and what has to be true before strangers see it.",
                                        recentlyChanged: true,
                                        anchor: .zero))
    }
    .frame(width: 400, height: 240)
    .preferredColorScheme(.dark)
}

#Preview("Sky door — glow rim") {
    Theme.bg
        .frame(width: 460, height: 140)
        .toolbar {
            SkyDoorToolbarItem(icon: "doc.plaintext", label: "Reader View", help: "") {}
        }
        .preferredColorScheme(.dark)
}

#Preview("Night Sky — real vault") {
    NightSkyView(vault: KnowledgeVault.load(), model: NightSkyModel(), onOpen: { _ in }, onExit: {})
        .frame(width: 1280, height: 800)
        .preferredColorScheme(.dark)
}
