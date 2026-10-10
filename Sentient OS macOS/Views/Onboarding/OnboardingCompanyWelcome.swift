// OnboardingCompanyWelcome.swift
// A company welcome between email entry and source selection. The original Sentient icon and
// spectrum breathe around the two logos; staged motion yields to accessibility and window focus.
// Doc: Documentation - Onboarding.md

import AppKit
import ImageIO
import SwiftUI

struct OnboardingCompanyWelcome: View {
    let company: YCCompanyWelcome
    let onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    var body: some View {
        VStack(spacing: 0) {
            MonoCaps("A personal welcome", size: 9, tracking: 2.8, color: Theme.secondary)
                .padding(.top, 38)
                .modifier(WelcomeArrival(arrived: arrived, delay: 0, reduceMotion: reduceMotion))

            ZStack {
                WelcomeAtmosphere()
                HStack(spacing: 33) {
                    logoMedallion {
                        Image("SentientLogo")
                            .renderingMode(.original)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 104, height: 104)
                    }
                    .accessibilityLabel("Sentient OS logo")
                    .modifier(WelcomeArrival(arrived: arrived, delay: 0.06, reduceMotion: reduceMotion, x: -18))

                    Text("×")
                        .font(.system(size: 25, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.42))
                        .accessibilityHidden(true)
                        .modifier(WelcomeArrival(arrived: arrived, delay: 0.2, reduceMotion: reduceMotion))

                    logoMedallion {
                        WelcomeCompanyLogo(company: company)
                    }
                    .accessibilityLabel("\(company.companyName) logo")
                    .modifier(WelcomeArrival(arrived: arrived, delay: 0.12, reduceMotion: reduceMotion, x: 18))
                }
            }
            .frame(height: 204)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 13) {
                    Text("Sentient OS")
                    Text("×").foregroundStyle(Theme.secondary)
                    Text(verbatim: company.companyName)
                }
                .display(30)
                .fixedSize()

                VStack(spacing: 7) {
                    Text("Sentient OS ×").display(23).foregroundStyle(Theme.Ink.bright)
                    Text(verbatim: company.companyName).display(30)
                        .lineLimit(2).minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sentient OS for \(company.companyName)")
            .accessibilityAddTraits(.isHeader)
            .modifier(WelcomeArrival(arrived: arrived, delay: 0.2, reduceMotion: reduceMotion))

            Text(verbatim: company.welcomeLine)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.Ink.bright)
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .lineLimit(4).minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 450)
                .padding(.top, 18)
                .modifier(WelcomeArrival(arrived: arrived, delay: 0.3, reduceMotion: reduceMotion))

            VStack(spacing: 6) {
                Text("From your fellow YC founders.")
                if let attribution = company.displayAttributionLine {
                    Text(verbatim: attribution)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 450)
            .padding(.top, 18)
            .modifier(WelcomeArrival(arrived: arrived, delay: 0.38, reduceMotion: reduceMotion))

            // The existing CTA supplies the shared Sentient spectrum. Reduced Motion gets
            // a static white capsule; no continuously spinning halo behind the button.
            OnboardingNextButton(title: "Let’s get started", glow: reduceMotion ? 0 : 0.36,
                                 minimumLabelWidth: 180, action: onContinue)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 34)
                .padding(.bottom, 30)
                .modifier(WelcomeArrival(arrived: arrived, delay: 0.4, reduceMotion: reduceMotion))
        }
        .padding(.horizontal, 40)
        .frame(width: 620)
        .background(Theme.bg)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LinearGradient(colors: [.clear, .white.opacity(0.18), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
                .padding(.horizontal, 60)
                .accessibilityHidden(true)
        }
        .preferredColorScheme(.dark)
        .onAppear { arrived = true }
        .onExitCommand(perform: onContinue)
    }

    private func logoMedallion<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: 104, height: 104)
            .background {
                Circle().fill(Color(white: 0.035))
                    .overlay {
                        Circle().fill(LinearGradient(colors: [.white.opacity(0.07), .clear],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
            }
            .overlay {
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.06)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.65), radius: 20, y: 10)
    }
}

private struct WelcomeArrival: ViewModifier {
    let arrived: Bool
    let delay: Double
    let reduceMotion: Bool
    var x: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .opacity(arrived || reduceMotion ? 1 : 0)
            .offset(x: arrived || reduceMotion ? 0 : x, y: arrived || reduceMotion ? 0 : 10)
            .blur(radius: arrived || reduceMotion ? 0 : 4)
            .animation(reduceMotion ? nil : .smooth(duration: 0.8).delay(delay), value: arrived)
    }
}

/// The glow is rasterized once, then breathed by the compositor. No per-frame state writes.
private struct WelcomeAtmosphere: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var active

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !active)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let breath = (sin(t.truncatingRemainder(dividingBy: 5.5) * 2 * .pi / 5.5) + 1) / 2
            let orbit = t.truncatingRemainder(dividingBy: 90) * 4
            ZStack {
                WelcomeLightTexture()
                    .scaleEffect(x: 0.96 + breath * 0.06, y: 0.92 + breath * 0.12)
                    .opacity(0.55 + breath * 0.16)

                Ellipse()
                    .stroke(AngularGradient(colors: GlowHalo.stops.map { $0.opacity(0.55) },
                                            center: .center, angle: .degrees(orbit)), lineWidth: 0.7)
                    .frame(width: 368, height: 102)
                    .rotationEffect(.degrees(-12))
                    .opacity(0.25 + breath * 0.2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WelcomeLightTexture: View {
    var body: some View {
        Ellipse()
            .fill(AngularGradient(colors: GlowHalo.stops, center: .center, angle: .degrees(150)))
            .frame(width: 300, height: 88)
            .blur(radius: 44)
            .padding(100)
            .drawingGroup()
    }
}

/// A missing or unusable logo leaves a deliberate company monogram, never an empty image.
private struct WelcomeCompanyLogo: View {
    let company: YCCompanyWelcome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Text(verbatim: String(company.companyName.prefix(1)).uppercased())
                    .font(.system(size: 39, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 62, height: 62)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: image != nil)
        .accessibilityHidden(true)
        .task(id: company.logoPath) {
            image = nil
            guard let data = await YCWelcomeClient.shared.logoData(for: company), !Task.isCancelled,
                  let thumbnail = await Self.thumbnail(from: data), !Task.isCancelled else { return }
            image = NSImage(cgImage: thumbnail, size: .zero)
        }
    }

    // Decode away from the UI, bounded in compressed size by the client and pixel size here.
    @concurrent private static func thumbnail(from data: Data) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              (1...4096).contains(width), (1...4096).contains(height) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 192,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }
}

#if DEBUG
extension YCCompanyWelcome {
    static let preview = YCCompanyWelcome(companyName: "Acme", welcomeLine:
        "Keep customer follow-ups moving while you build what comes next.", logoPath: nil, contentVersion: 1)
}

#Preview("Company welcome") {
    OnboardingCompanyWelcome(company: .preview, onContinue: {})
}

#Preview("Long company name") {
    OnboardingCompanyWelcome(company: YCCompanyWelcome(companyName: "The Very Thoughtful Robotics Company",
        welcomeLine: "Keep supplier conversations, meeting preparation, and the next steps in view.",
        logoPath: nil, contentVersion: 1), onContinue: {})
}
#endif
