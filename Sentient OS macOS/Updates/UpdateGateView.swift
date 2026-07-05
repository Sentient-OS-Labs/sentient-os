//
//  UpdateGateView.swift
//  Sentient OS macOS
//
//  The OLED forced-update surface. Two faces, chosen by UpdateModel.surface:
//   • gate — a full-screen, non-dismissible takeover when a mandatory update is found or installing.
//     One action: Update. (Plus Quit, so a modal never traps the user.) No "skip" / "remind me".
//   • info — a small dismissible card for a user-initiated check: "Checking…", "You're up to date",
//     or "Couldn't check". Never shown for a silent background check.
//  Rendered as an overlay by RootView; draws nothing when surface == .none.
//
//  Design bar: true-black, editorial serif titles, mono-caps whispers, the spinning AI-spectrum
//  logo as the living mark, the glow CTA. Reuses Theme / GlowButton / SpinningLogo.
//

import SwiftUI
import AppKit

struct UpdateGateView: View {
    @Environment(AppState.self) private var appState
    private var model: UpdateModel { appState.update.model }

    var body: some View {
        ZStack {
            switch model.surface {
            case .none:
                Color.clear.allowsHitTesting(false)
            case .gate:
                gate.transition(.opacity)
            case .info:
                infoCard.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.surface)
        .animation(.easeInOut(duration: 0.35), value: model.phase)
        .onChange(of: model.surface) { _, surface in
            // A gate or info surface just appeared — bring Sentient forward so it's seen even if it
            // was in the background or the user triggered the check from the Settings window.
            if surface != .none { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
    }

    // MARK: - The mandatory full-screen gate

    private var gate: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                SpinningLogo(size: 66, fast: isWorking)
                    .padding(.bottom, 30)

                MonoCaps("Software Update", size: 10, tracking: 2.6, color: Theme.Ink.label)
                    .padding(.bottom, 14)

                Text(gateTitle)
                    .font(.serif(30)).italic()
                    .foregroundStyle(Theme.Ink.statusInk)
                    .multilineTextAlignment(.center)

                Text(gateBody)
                    .font(.system(size: 13)).foregroundStyle(Theme.Ink.body)
                    .lineSpacing(3.5)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                gateStatus
                    .padding(.top, 28)

                Spacer()

                footer
            }
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Progress + actions, per phase.
    @ViewBuilder private var gateStatus: some View {
        switch model.phase {
        case .found(let version):
            VStack(spacing: 16) {
                MonoCaps("Required to keep going · v\(version)", size: 9, tracking: 2, color: Theme.Ink.deepMuted)
                GlowButton(title: "Update Now", systemImage: "arrow.down.circle.fill") {
                    model.installNow()
                }
                .frame(maxWidth: 320)
                quitButton
            }

        case .downloading(let fraction):
            VStack(spacing: 18) {
                UpdateProgressBar(value: fraction).frame(maxWidth: 340)
                MonoCaps(downloadLabel(fraction), size: 9, tracking: 2, color: Theme.Ink.label)
                quitButton
            }

        case .extracting(let fraction):
            VStack(spacing: 18) {
                UpdateProgressBar(value: fraction).frame(maxWidth: 340)
                MonoCaps("Preparing update", size: 9, tracking: 2, color: Theme.Ink.label)
                quitButton
            }

        case .installing:
            VStack(spacing: 18) {
                UpdateProgressBar(value: nil).frame(maxWidth: 340)
                MonoCaps("Installing · Sentient will restart", size: 9, tracking: 2, color: Theme.Ink.label)
            }

        case .failed(let message, _):
            VStack(spacing: 16) {
                Text(message)
                    .font(.system(size: 12)).foregroundStyle(Theme.Ink.amber)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
                GlowButton(title: "Try Again", systemImage: "arrow.clockwise") {
                    model.dismissInfo()                 // acknowledge the error, reset
                    appState.update.checkForUpdatesNow()
                }
                .frame(maxWidth: 320)
                quitButton
            }

        default:
            EmptyView()
        }
    }

    // MARK: - The small info card (user-initiated check)

    private var infoCard: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { if canDismissInfo { model.dismissInfo() } }

            VStack(spacing: 16) {
                switch model.phase {
                case .checking:
                    ProgressView().controlSize(.small).tint(.white.opacity(0.5))
                    Text("Checking for updates…")
                        .font(.serif(17)).italic().foregroundStyle(Theme.Ink.statusInk)
                    Button("Cancel") { model.dismissInfo() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.label)
                        .padding(.top, 2)

                case .upToDate:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26)).foregroundStyle(Theme.Ink.green)
                    Text("You're up to date.")
                        .font(.serif(19)).italic().foregroundStyle(Theme.Ink.statusInk)
                    Text("Sentient is on version \(UpdateController.currentVersionString).")
                        .font(.system(size: 12)).foregroundStyle(Theme.Ink.body)
                    doneButton

                case .failed(let message, _):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 22)).foregroundStyle(Theme.Ink.amber)
                    Text("Couldn't check for updates.")
                        .font(.serif(18)).italic().foregroundStyle(Theme.Ink.statusInk)
                    Text(message)
                        .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.body)
                        .multilineTextAlignment(.center).frame(maxWidth: 280)
                        .fixedSize(horizontal: false, vertical: true)
                    doneButton

                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 34).padding(.vertical, 30)
            .frame(width: 360)
            .background(Color(white: 0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 40, y: 16)
        }
    }

    // MARK: - Shared bits

    private var quitButton: some View {
        Button(action: { model.quit() }) {
            Text("Quit Sentient")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 22).padding(.vertical, 9)
                .background(Capsule().fill(.white.opacity(0.06)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    private var doneButton: some View {
        Button(action: { model.dismissInfo() }) {
            Text("Done")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.black)
                .padding(.horizontal, 26).padding(.vertical, 8)
                .background(Capsule().fill(.white))
        }
        .buttonStyle(PressScaleStyle())
        .padding(.top, 4)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield").font(.system(size: 10.5)).foregroundStyle(Theme.Ink.label)
            Text("Private by design. Your files never leave this Mac.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.label)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
    }

    // MARK: - Copy & state helpers

    private var isWorking: Bool {
        switch model.phase {
        case .downloading, .extracting, .installing: return true
        default: return false
        }
    }

    private var canDismissInfo: Bool {
        switch model.phase {
        case .upToDate, .failed: return true
        default: return false     // don't let a tap dismiss the "checking…" spinner
        }
    }

    private var gateTitle: String {
        switch model.phase {
        case .found:        return "A new Sentient is ready."
        case .downloading:  return "Updating Sentient…"
        case .extracting:   return "Almost there…"
        case .installing:   return "Installing…"
        case .failed:       return "Update didn't finish."
        default:            return ""
        }
    }

    private var gateBody: String {
        switch model.phase {
        case .found:
            return "To keep doing things for you safely, Sentient always runs the latest version. This one's quick — one tap and you're set."
        case .downloading, .extracting:
            return "Hang tight while Sentient updates itself."
        case .installing:
            return "Sentient is installing the update and will reopen in a moment."
        case .failed:
            return "Something interrupted the update. Let's try that again."
        default:
            return ""
        }
    }

    private func downloadLabel(_ fraction: Double?) -> String {
        guard let fraction else { return "Downloading update" }
        return "Downloading · \(Int(fraction * 100))%"
    }
}

/// A slim OLED progress bar in the AI spectrum. `value` nil = indeterminate (a segment sliding on a
/// loop); otherwise a determinate gradient fill with a soft tip glow.
private struct UpdateProgressBar: View {
    var value: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))

                if let value {
                    Capsule()
                        .fill(LinearGradient(colors: GlowHalo.stops, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, w * max(0, min(1, value))))
                        .shadow(color: Color(red: 0.61, green: 0.28, blue: 0.83).opacity(0.6), radius: 8)
                        .animation(.easeInOut(duration: 0.25), value: value)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
                        let seg = w * 0.34
                        let period = 1.25
                        let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                        let x = (w + seg) * t - seg
                        Capsule()
                            .fill(LinearGradient(colors: GlowHalo.stops, startPoint: .leading, endPoint: .trailing))
                            .frame(width: seg)
                            .offset(x: x)
                            .shadow(color: Color(red: 0.61, green: 0.28, blue: 0.83).opacity(0.5), radius: 8)
                    }
                    .mask(Capsule())
                }
            }
        }
        .frame(height: 8)
    }
}
