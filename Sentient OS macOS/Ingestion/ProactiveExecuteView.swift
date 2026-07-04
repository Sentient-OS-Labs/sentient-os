//
//  ProactiveExecuteView.swift
//  Sentient OS macOS
//
//  PROACTIVE · EXECUTE — the dev window for PART 3 (the executor). Opened by the DEV TOOLS
//  "proactive EXECUTE" button. Lists the REAL ready-to-fire `PreparedAction`s from the most recent
//  PART 2 run (ProactiveResearch.latest) — exactly what Step 1 (judge) + Step 2 (research+prepare)
//  produced — each with its draft + recipe and a working FIRE button that calls ProactiveExecutor
//  for real (Gmail MCP send / computer use / calendar MCP). No mock theater: the
//  status line shows the actual codex outcome. Sibling to ProactiveItemsView (VIEW ACTION ITEMS).
//

import SwiftUI
import AppKit

struct ProactiveExecuteView: View {
    static let windowID = "proactive-execute"

    @State private var result: ReadyResult?
    @State private var loaded = false
    @State private var expanded: Set<String> = []
    @State private var model = ExecRunModel()

    private var ready: [PreparedAction] { result?.ready ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            if loaded && ready.isEmpty {
                Spacer()
                Text("No ready-to-fire actions — run “proactive system” (part 1) then “proactive RESEARCH + PREPARE” (part 2) first.")
                    .font(.callout).foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center).padding(40)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(ready) { action in
                            row(action)
                            Divider().overlay(Theme.stroke)
                        }
                        if let dropped = result?.dropped, !dropped.isEmpty {
                            droppedFooter(dropped)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 760)
        .background(Theme.bg)
        .onAppear { load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "paperplane.fill").foregroundStyle(.orange)
            Text("PROACTIVE · EXECUTE — \(ready.count) ready").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Theme.faint)
            Spacer()
            Text("PART 3 — fires for real").font(.caption2).foregroundStyle(Theme.faint)
            Button("Refresh") { load() }.controlSize(.small).disabled(model.busy != nil)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    // MARK: One action row

    private func row(_ a: PreparedAction) -> some View {
        let isExpanded = expanded.contains(a.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                methodBadge(a.method)
                statusBadge(a.status)
                if let due = a.dueDate, !due.isEmpty {
                    Label(due, systemImage: "calendar").font(.caption2.weight(.medium)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if !a.reviewNote.isEmpty {
                    Label("check first", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                }
            }

            Text(a.title).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if !a.cardSummary.isEmpty {
                Text(a.cardSummary).font(.caption).foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Fire + copy + expand controls
            HStack(spacing: 10) {
                fireButton(a)
                Button {
                    copy(a.preparedContent.isEmpty ? a.executionRecipe : a.preparedContent)
                    model.status[a.id] = "✓ draft copied"
                } label: {
                    Label("Copy draft", systemImage: "doc.on.doc").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)

                Button { toggle(a.id) } label: {
                    Label(isExpanded ? "Hide details" : "Details", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
            }

            if let s = model.status[a.id] {
                Text(s)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(statusColor(s))
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if isExpanded { details(a) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 13)
    }

    private func fireButton(_ a: PreparedAction) -> some View {
        let fireable = ProactiveExecutor.isFireable(a.method)
        return Button {
            fire(a)
        } label: {
            HStack(spacing: 6) {
                if model.busy == a.id { ProgressView().controlSize(.small) }
                else { Image(systemName: fireIcon(a.method)) }
                Text(fireLabel(a.method)).font(.caption.weight(.semibold))
            }
            .frame(minWidth: 150, minHeight: 30)
        }
        .buttonStyle(.borderedProminent).tint(.orange)
        .disabled(!fireable || model.busy != nil)
    }

    @ViewBuilder private func details(_ a: PreparedAction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            detailBlock("PREPARED CONTENT (the draft)", a.preparedContent)
            detailBlock("EXECUTION RECIPE (what fire runs)", a.executionRecipe)
            if !a.reviewNote.isEmpty { detailBlock("REVIEW NOTE", a.reviewNote, tint: .orange) }
            if !a.verification.isEmpty { detailBlock("VERIFICATION", a.verification) }
            if !a.sources.isEmpty {
                detailBlock("SOURCES", a.sources.joined(separator: "  ·  "))
            }
        }
        .padding(.top, 4)
    }

    private func detailBlock(_ title: String, _ body: String, tint: Color = Theme.faint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(tint)
            Text(body.isEmpty ? "—" : body)
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func droppedFooter(_ dropped: [DroppedItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DROPPED · \(dropped.count)").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(Theme.faint)
            ForEach(dropped) { d in
                Text("✗ \(d.title) — \(d.reason)").font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
    }

    // MARK: badges

    private func methodBadge(_ m: PreparedAction.Method) -> some View {
        let (label, color): (String, Color) = {
            switch m {
            case .gmail:    return ("GMAIL", Color(red: 1.00, green: 0.50, blue: 0.18))
            case .calendar: return ("CALENDAR", Color(red: 0.36, green: 0.55, blue: 1.00))
            case .computer: return ("COMPUTER USE", Theme.Ink.green)
            case .research: return ("RESEARCHED", Theme.secondary)
            }
        }()
        return Text(label).font(.system(size: 8, weight: .bold)).tracking(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
    }

    private func statusBadge(_ s: PreparedAction.Status) -> some View {
        let (label, color): (String, Color) = {
            switch s {
            case .confirmed:  return ("CONFIRMED", Theme.Ink.green)
            case .updated:    return ("UPDATED", Color(red: 1.00, green: 0.78, blue: 0.28))
            case .unverified: return ("UNVERIFIED", Theme.secondary)
            }
        }()
        return Text(label).font(.system(size: 8, weight: .bold)).tracking(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule()).foregroundStyle(color)
    }

    // MARK: actions

    private func fire(_ a: PreparedAction) {
        guard model.busy == nil else { return }
        model.busy = a.id
        model.status[a.id] = "…"
        let id = a.id
        let progress: @Sendable (String) -> Void = { s in Task { @MainActor in model.status[id] = s } }
        Task {
            let outcome = await ProactiveExecutor.shared.fire(a, progress: progress)
            await MainActor.run {
                switch outcome {
                case .fired(let m):       model.status[id] = "✓ " + m
                case .notFireable(let m): model.status[id] = "⚠︎ " + m
                case .failed(let m):      model.status[id] = "✗ " + m
                }
                model.busy = nil
            }
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func load() {
        result = ProactiveResearch.latest()
        loaded = true
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func statusColor(_ s: String) -> Color {
        if s.hasPrefix("✓") { return Theme.Ink.green }
        if s.hasPrefix("✗") { return .red }
        if s.hasPrefix("⚠︎") { return .orange }
        return Theme.secondary
    }

    private func fireLabel(_ m: PreparedAction.Method) -> String {
        switch m {
        case .gmail:    return "Send it for you"
        case .computer: return "Run on your Mac"
        case .calendar: return "Add to calendar"
        case .research: return "Nothing to fire"
        }
    }

    private func fireIcon(_ m: PreparedAction.Method) -> String {
        switch m {
        case .gmail:    return "paperplane.fill"
        case .computer: return "desktopcomputer"
        case .calendar: return "calendar.badge.plus"
        case .research: return "minus.circle"
        }
    }
}

/// Tracks which action is firing + each action's latest status line. MainActor so the background
/// run's `@Sendable` progress callback can update it safely.
@MainActor
@Observable
final class ExecRunModel {
    var busy: String?
    var status: [String: String] = [:]
}
