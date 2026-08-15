//
//  ProactiveItemsView.swift
//  Sentient OS macOS
//
//  VIEW ACTION ITEMS — a dev list of the most recent proactive JUDGE run (Proactive.findActionItems),
//  shown in full detail: urgency, due date, the action, WHY it matters (the dots the model connected),
//  and the source evidence. Reads the persisted last run (Proactive.latest); sibling to SummariesView.
//

import SwiftUI

struct ProactiveItemsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ActionItem] = []
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ACTION ITEMS · \(items.count)")
                    .font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Theme.faint)
                Spacer()
                Button("Refresh") { load() }.controlSize(.small)
                Button("Done") { dismiss() }.controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)

            if loaded && items.isEmpty {
                Spacer()
                Text("No action items yet — run “proactive system”.")
                    .font(.callout).foregroundStyle(Theme.faint)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                            row(item, index: idx)
                            Divider().overlay(Theme.stroke)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 8)
                }
            }
        }
        .frame(width: 660, height: 720)
        .background(Theme.bg)
        .onAppear { load() }
    }

    private func row(_ item: ActionItem, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
                urgencyBadge(item.urgency)
                if let due = item.dueDate, !due.isEmpty {
                    Label(due, systemImage: "calendar")
                        .font(.caption2.weight(.medium)).foregroundStyle(Theme.secondary)
                }
                Spacer()
            }
            Text(item.title)
                .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if !item.action.isEmpty {
                Text(item.action)
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.importance.isEmpty {
                Text(item.importance)
                    .font(.caption).italic().foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.sources.isEmpty {
                Text("Sources: " + item.sources.joined(separator: "  ·  "))
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private func urgencyBadge(_ u: ActionItem.Urgency) -> some View {
        let (label, color): (String, Color) = {
            switch u {
            case .high:   return ("HIGH",   Color(red: 1.00, green: 0.45, blue: 0.45))
            case .medium: return ("MEDIUM", Color(red: 1.00, green: 0.78, blue: 0.28))
            case .low:    return ("LOW",    Theme.secondary)
            }
        }()
        return Text(label)
            .font(.system(size: 8, weight: .bold)).tracking(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func load() {
        items = Proactive.latest()
        loaded = true
    }
}
