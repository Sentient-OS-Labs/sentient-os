//
// ConnectorLogo.swift
// Shared brand artwork for source pills and connection sheets. Keep original colors and
// alpha; Granola's square artwork uses a continuous squircle mask at every size.
// Apple Mail, Apple Notes, Messages and WhatsApp artwork is exported from the installed macOS apps.
// Doc: Documentation - Views - Home, Processing & Shared UI.md
//

import SwiftUI

struct ConnectorLogo: View {
    let asset: String
    var size: CGFloat = 34

    /// Match visible weight inside a fixed layout slot. Exported Mac app icons have
    /// about 19% transparent padding; the solid square marks need a little breathing room.
    private var artworkScale: CGFloat {
        switch asset {
        case "WhatsAppMark", "IMessageMark", "AppleNotesMark", "AppleMailMark", "AppleCalendarMark": 1.11
        case "GoogleCalendarMark", "GranolaMark": 0.9
        case "OutlookMark": 0.95
        default: 1
        }
    }

    var body: some View {
        Image(asset)
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size * artworkScale, height: size * artworkScale)
            .clipShape(RoundedRectangle(cornerRadius: asset == "GranolaMark" ? size * artworkScale * 0.23 : 0,
                                        style: .continuous))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

#Preview("Connection logos · on black") {
    HStack(alignment: .top, spacing: 28) {
        ForEach(["GmailMark", "GoogleCalendarMark", "GoogleDriveMark", "SlackMark",
                 "OutlookMark", "NotionMark", "GranolaMark", "WhatsAppMark", "IMessageMark",
                 "AppleNotesMark", "AppleMailMark", "AppleCalendarMark"], id: \.self) { asset in
            VStack(spacing: 16) {
                ConnectorLogo(asset: asset)
                Text(asset.replacingOccurrences(of: "Mark", with: ""))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
            }
            .frame(width: 72)
        }
    }
    .padding(36).background(.black)
}
