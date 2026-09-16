//
// ConnectorLogo.swift
// Shared brand artwork for connection sheets. Assets are trimmed to their visible bounds,
// so 34 points means the same visible height as Gmail and Google Calendar. Keep original
// colors and alpha; template tinting or opacity would change the providers' artwork.
// Doc: Documentation - Views - Home, Processing & Shared UI.md
//

import SwiftUI

struct ConnectorLogo: View {
    let asset: String

    var body: some View {
        Image(asset)
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(height: 34)
            .accessibilityHidden(true)
    }
}

#Preview("Connection logos · on black") {
    HStack(alignment: .top, spacing: 28) {
        ForEach(["GmailMark", "GoogleCalendarMark", "GoogleDriveMark", "SlackMark",
                 "OutlookMark", "NotionMark", "GranolaMark"], id: \.self) { asset in
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
