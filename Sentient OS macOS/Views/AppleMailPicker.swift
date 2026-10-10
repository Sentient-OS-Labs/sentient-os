// AppleMailPicker.swift
// Explicit account opt-in, Mail-specific access errors, and retry. Opening never enables a source.
// Doc: Settings/Documentation - Settings.md

import SwiftUI

struct AppleMailPicker: View {
    var onDone: (Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [AppleMailAccount] = []
    @State private var selected = Set<String>()
    @State private var researchEnabled = false
    @State private var loading = true
    @State private var failed = false
    @State private var failureMessage = ""
    @State private var accessIssue = false
    #if DEBUG
    private var previewing = false
    #endif

    init(initialSelection: Set<String>, onDone: @escaping (Set<String>) -> Void) {
        self.onDone = onDone
        _selected = State(initialValue: initialSelection)
        _researchEnabled = State(initialValue: AppleMailResearchAccess.scope != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            ConnectorLogo(asset: "AppleMailMark")
            Text("Apple Mail").display(20).foregroundStyle(Theme.Ink.statusInk).padding(.top, 18)
            Text("Choose the accounts to include.")
                .font(.system(size: 12)).foregroundStyle(Theme.Ink.body).padding(.top, 10)
            accountList.padding(.top, 22)
            Toggle("Read emails for proactive suggestions", isOn: $researchEnabled)
                .toggleStyle(.checkbox).font(.system(size: 12)).padding(.top, 18)
            Text("Your chosen AI can read actual email text from these accounts to check and prepare suggestions. A cloud AI processes that text with its provider. This access only reads mail.")
                .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Text("Cancel").font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.Ink.bright)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Capsule().fill(.white.opacity(0.07)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle()).keyboardShortcut(.cancelAction)
                Button { AppleMailResearchAccess.save(accounts: researchEnabled ? selected : []); onDone(selected); dismiss() } label: {
                    Text("Done").font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Capsule().fill(.white))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle()).keyboardShortcut(.defaultAction)
                .disabled(loading || (failed && !selected.isEmpty))
                .opacity(loading || (failed && !selected.isEmpty) ? 0.4 : 1)
            }.padding(.top, 24)
            Button("Deselect all") { selected.removeAll() }
                .buttonStyle(.plain).font(.system(size: 11))
                .foregroundStyle(Theme.Ink.body).padding(.top, 16)
                .disabled(loading || selected.isEmpty)
                .opacity(selected.isEmpty ? 0 : 1).accessibilityHidden(selected.isEmpty)
        }
        .padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 24)
        .frame(width: 460).background(Theme.bg)
        .overlay(alignment: .topLeading) { CloseHoverButton { dismiss() }.padding(12) }
        .task {
            #if DEBUG
            if previewing { return }
            #endif
            await load()
        }
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 14) {
            if loading { ProgressView("Loading accounts…").frame(maxWidth: .infinity, minHeight: 80) }
            else if failed {
                Text(failureMessage)
                    .font(.system(size: 12)).foregroundStyle(Theme.Ink.body)
                HStack {
                    if accessIssue { Button("Open Full Disk Access") { Permissions.openFullDiskAccessSettings() } }
                    Button("Try Again") { Task { await load() } }
                }
            } else if accounts.isEmpty {
                Text("No Mail accounts found. Add an account in Apple Mail, then try again.")
                    .font(.system(size: 12)).foregroundStyle(Theme.Ink.body)
                Button("Try Again") { Task { await load() } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(accounts) { account in
                            Toggle(account.name, isOn: Binding(get: { selected.contains(account.id) }, set: {
                                if $0 { selected.insert(account.id) } else { selected.remove(account.id) }
                            })).toggleStyle(.checkbox).font(.system(size: 13))
                        }
                        ForEach(Array(selected.subtracting(accounts.map(\.id))).sorted(), id: \.self) { id in
                            Toggle("Unavailable account", isOn: Binding(get: { selected.contains(id) }, set: { if !$0 { selected.remove(id) } }))
                                .toggleStyle(.checkbox).font(.system(size: 13)).foregroundStyle(Theme.Ink.body)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }.frame(height: min(CGFloat(accounts.count + selected.subtracting(accounts.map(\.id)).count) * 38 + 16, 230))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        loading = true; failed = false; accessIssue = false
        do { accounts = try await Task.detached(priority: .utility) { try AppleMailSource.accounts() }.value }
        catch {
            failed = true
            if case AppleMailError.unsupportedSchema = error {
                failureMessage = "This version of Apple Mail isn’t supported yet."
            } else {
                accessIssue = true
                failureMessage = "Allow Full Disk Access in System Settings, then relaunch Sentient."
            }
        }
        loading = false
    }

    #if DEBUG
    static var researchPreview: AppleMailPicker {
        var view = AppleMailPicker(initialSelection: ["work"]) { _ in }
        view.previewing = true
        view._accounts = State(initialValue: [.init(id: "work", name: "Work"), .init(id: "personal", name: "Personal")])
        view._loading = State(initialValue: false)
        view._researchEnabled = State(initialValue: true)
        return view
    }
    #endif
}

#if DEBUG
#Preview { AppleMailPicker.researchPreview.environment(\.colorScheme, .dark) }
#endif
