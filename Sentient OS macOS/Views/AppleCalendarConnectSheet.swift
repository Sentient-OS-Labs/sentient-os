// AppleCalendarConnectSheet.swift
// User-triggered Calendar consent and explicit per-calendar selection, shared by Settings
// and onboarding. Merely opening the sheet or running analysis never asks for permission.
// Doc: Settings/Documentation - Settings.md

import SwiftUI
import EventKit
import AppKit

struct AppleCalendarConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var authorization = EKEventStore.authorizationStatus(for: .event)
    @State private var calendars: [AppleCalendarSource.CalendarInfo] = []
    @State private var selected = AppleCalendarSource.selectedIDs
    @State private var loading = false
    @State private var loaded = false
    @State private var message: String?
    @AppStorage(AppleCalendarSource.issueKey) private var readIssue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                ConnectorLogo(asset: "AppleCalendarMark", size: 32)
                Text("Apple Calendar").display(26)
                Spacer()
            }
            Text("Choose the calendars Sentient reads on this Mac.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            if authorization == .fullAccess {
                if loading { ProgressView().controlSize(.small) }
                else if loaded && calendars.isEmpty {
                    Text("No calendars are available. Add an account in Apple Calendar, then refresh.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(calendars) { calendar in
                                Toggle(isOn: Binding(get: { selected.contains(calendar.id) }, set: { value in
                                    if value { selected.insert(calendar.id) } else { selected.remove(calendar.id) }
                                })) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(calendar.title).font(.system(size: 13))
                                        Text(calendar.account).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                    }
                                }.toggleStyle(.checkbox)
                            }
                            let missing = selected.subtracting(Set(calendars.map(\.id)))
                            if !missing.isEmpty {
                                Text("\(missing.count) previously selected calendars are unavailable. Refresh or remove them to resume analysis.")
                                    .font(.system(size: 12)).foregroundStyle(Theme.Ink.amber)
                                Button("Remove unavailable calendars") { selected.subtract(missing) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 80, maxHeight: 260)
                }
                HStack {
                    Button("Refresh") { Task { await refresh() } }
                    Button("Clear selection") { selected.removeAll() }
                }.disabled(loading)
            } else {
                Text(permissionExplanation).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                if authorization == .notDetermined || authorization == .writeOnly {
                    Button("Allow Calendar Access") { Task { await connect() } }.disabled(loading)
                } else if authorization == .denied {
                    Button("Open Calendar Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }
            }
            if !PipelineActivity.shared.isRunning, let issue = AppleCalendarSource.issueMessage(readIssue) {
                Text(issue).font(.system(size: 12)).foregroundStyle(Theme.Ink.amber)
            }
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(Theme.Ink.amber) }
            if PipelineActivity.shared.isRunning {
                Text("You can change calendar selections after analysis finishes.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Selection") {
                    AppleCalendarSource.saveSelection(selected)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loading || !loaded || authorization != .fullAccess || PipelineActivity.shared.isRunning)
            }
        }
        .padding(28).frame(width: 510).background(Theme.bg).foregroundStyle(.white)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await refresh() }
        }
    }

    private var permissionExplanation: String {
        switch authorization {
        case .restricted: "Calendar access is restricted on this Mac. Your administrator can help change it."
        case .denied: "Calendar access is off. Enable Full Access for Sentient in System Settings to read your selected calendars."
        default: "macOS calls permission to read calendars ‘Full Access’. Sentient uses it here only to read the calendars you choose. No separate sign-in is needed."
        }
    }

    private func connect() async {
        guard !loading else { return }
        loading = true; message = nil
        do { _ = try await AppleCalendarSource.requestAccess() }
        catch { message = "Calendar access could not be requested. Try again or check System Settings." }
        loading = false
        await refresh()
    }

    private func refresh() async {
        guard !loading else { return }
        authorization = EKEventStore.authorizationStatus(for: .event)
        guard authorization == .fullAccess else { calendars = []; loaded = false; return }
        loading = true; message = nil
        defer { loading = false }
        do {
            calendars = try await Task.detached(priority: .userInitiated) { try AppleCalendarSource.calendars() }.value
            loaded = true
        } catch {
            loaded = false
            message = "Your calendars could not be read. Check access in System Settings, then refresh."
        }
        authorization = EKEventStore.authorizationStatus(for: .event)
    }
}

#Preview("Apple Calendar connection") {
    AppleCalendarConnectSheet()
}
