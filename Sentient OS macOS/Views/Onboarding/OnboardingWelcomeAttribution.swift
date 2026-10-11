// The welcome's founder signature: a heart and two quiet, copyable contact cards.
// Formats the existing optional attribution payload without embedding contact details in the app.
// Doc: Documentation - Onboarding.md

import AppKit
import SwiftUI

struct OnboardingWelcomeAttribution: View {
    let line: String

    var body: some View {
        if let contacts = WelcomeFounderContact.parse(line) {
            VStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("Made with")
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.52))
                    Text("by")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Made with love by")

                HStack(spacing: 12) {
                    ForEach(contacts, id: \.name) { contact in
                        WelcomeContactButton(contact: contact)
                    }
                }
            }
        } else if line.hasPrefix("Made with love ") {
            Text("Made with \(Image(systemName: "heart.fill")) \(String(line.dropFirst("Made with love ".count)))")
                .accessibilityLabel(line)
        } else {
            Text(verbatim: line)
        }
    }
}

private struct WelcomeContactButton: View {
    let contact: WelcomeFounderContact
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(contact.phone, forType: .string)
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: contact.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Ink.bright)
                    Text(verbatim: contact.phone)
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(Theme.secondary)
                }
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? Theme.Ink.green : Theme.secondary)
                    .frame(width: 14)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(.white.opacity(hovering ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white.opacity(hovering ? 0.14 : 0.07), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(copied ? "Number copied" : "Copy \(contact.name)’s number")
        .accessibilityLabel("\(contact.name), \(contact.phone)")
        .accessibilityValue(copied ? "Number copied" : "")
        .accessibilityHint("Copies the phone number")
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }
}

/// The server currently sends a single sentence. Recognize its two-contact form, preserving
/// other attribution copy verbatim; only presentation changes, never the source payload.
struct WelcomeFounderContact {
    let name: String
    let phone: String

    static func parse(_ line: String) -> [Self]? {
        let pattern = #"^Made with love by (.+?) \((\+?[0-9][0-9 ()-]*[0-9])\) and (.+?) \((\+?[0-9][0-9 ()-]*[0-9])\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        let fields = (1...4).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: line) else { return nil }
            return String(line[range])
        }
        guard fields.count == 4 else { return nil }
        return [Self(name: fields[0], phone: fields[1]), Self(name: fields[2], phone: fields[3])]
    }
}

#if DEBUG
#Preview("Founder contacts") {
    OnboardingWelcomeAttribution(line:
        "Made with love by Alex (+1 (202) 555-0101) and Sam (+1 (202) 555-0102)")
        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        .padding(40).background(.black).preferredColorScheme(.dark)
}
#endif
