// ConnectorActionButton.swift
// Matching white Connect and green checkmarked Done pills for connector popups.
// The connect variant also displays progress during browser sign-in.
// Doc: Documentation - Views - Home, Processing & Shared UI.md

import SwiftUI

struct ConnectorActionButton: View {
    enum Kind { case connect, done }

    let title: String
    var kind: Kind = .connect
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if kind == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                } else if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Capsule().fill(kind == .done ? Theme.Ink.green : .white))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

#Preview("Connector buttons") {
    VStack(spacing: 14) {
        ConnectorActionButton(title: "Connect Google Drive", action: {})
        ConnectorActionButton(title: "Done", kind: .done, action: {})
        ConnectorActionButton(title: "Waiting for sign-in…", isLoading: true, action: {})
            .disabled(true)
    }
    .padding(36).frame(width: 400).background(Theme.bg)
    .preferredColorScheme(.dark)
}
