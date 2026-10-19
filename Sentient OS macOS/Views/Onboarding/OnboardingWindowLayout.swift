// Fit the complete onboarding canvas above the Dock, using logical display space
// rather than a hardware-model list. Moving to a larger display restores 100%.
import AppKit
import SwiftUI

nonisolated enum OnboardingWindowLayout {
    static let canvas = CGSize(width: 1100, height: 820)
    static let minimum = CGSize(width: 1040, height: 800)
    static let edgeMargin: CGFloat = 12

    static func scale(visibleSize: CGSize, chrome: CGSize = CGSize(width: 0, height: 32)) -> CGFloat {
        let available = CGSize(width: max(1, visibleSize.width - edgeMargin * 2 - chrome.width),
                               height: max(1, visibleSize.height - edgeMargin * 2 - chrome.height))
        return min(1, available.width / canvas.width, available.height / canvas.height)
    }

    static func initialSize(visibleSize: CGSize) -> CGSize {
        let scale = scale(visibleSize: visibleSize)
        return CGSize(width: floor(canvas.width * scale), height: floor(canvas.height * scale))
    }

    static func fittedFrame(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
        let safe = visibleFrame.insetBy(dx: edgeMargin, dy: edgeMargin)
        let size = CGSize(width: min(frame.width, safe.width), height: min(frame.height, safe.height))
        return CGRect(x: min(max(frame.minX, safe.minX), safe.maxX - size.width),
                      y: min(max(frame.minY, safe.minY), safe.maxY - size.height),
                      width: size.width, height: size.height)
    }
}

/// Layout at full design size before scaling, so shrinking the window never clips
/// the fixed-height lessons or leaves their Continue buttons below the viewport.
struct OnboardingCanvas<Content: View>: View {
    let scale: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            content
                .environment(\.onboardingCanvasScale, scale)
                .frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        // The film and GitHub mark intentionally extend into the transparent title bar.
        // Clip only at the native window boundary, not this safe-area-sized canvas.
    }
}

private struct OnboardingCanvasScaleKey: EnvironmentKey {
    nonisolated static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var onboardingCanvasScale: CGFloat {
        get { self[OnboardingCanvasScaleKey.self] }
        set { self[OnboardingCanvasScaleKey.self] = newValue }
    }
}

struct OnboardingWindowFit: NSViewRepresentable {
    let active: Bool
    let onScale: (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.active = active; view.onScale = onScale
        view.refresh()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        var active = false
        var onScale: ((CGFloat) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var task: Task<Void, Never>?
        private var lastScale: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            guard let window else { task?.cancel(); return }
            for name in [NSWindow.didChangeScreenNotification,
                         NSWindow.didResizeNotification, NSApplication.didChangeScreenParametersNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name,
                    object: name == NSApplication.didChangeScreenParametersNotification ? nil : window, queue: .main) {
                    [weak self] _ in MainActor.assumeIsolated { self?.refresh() }
                })
            }
            refresh()
        }

        func refresh() {
            task?.cancel()
            guard active, let window, let screen = window.screen else { lastScale = nil; return }
            let content = window.contentRect(forFrameRect: window.frame)
            let chrome = CGSize(width: max(0, window.frame.width - content.width),
                                height: max(0, window.frame.height - content.height))
            let scale = OnboardingWindowLayout.scale(visibleSize: screen.visibleFrame.size, chrome: chrome)
            task = Task { @MainActor [weak self, weak window] in
                // Publish outside SwiftUI's update pass; then let its minimum-size change land.
                await Task.yield()
                guard let self, self.active, !Task.isCancelled, let window else { return }
                if self.lastScale != scale { self.lastScale = scale; self.onScale?(scale) }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard self.active, !window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
                let fitted = OnboardingWindowLayout.fittedFrame(window.frame, visibleFrame: screen.visibleFrame)
                if abs(fitted.minX - window.frame.minX) > 0.5 || abs(fitted.minY - window.frame.minY) > 0.5
                    || abs(fitted.width - window.frame.width) > 0.5 || abs(fitted.height - window.frame.height) > 0.5 {
                    window.setFrame(fitted, display: true)
                }
            }
        }

        func stop() {
            active = false; task?.cancel(); task = nil
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            onScale = nil
        }
    }
}
