import SwiftUI

/// Durable reply attachment, including after the suggestion leaves the home deck.
struct SidekickCardReplyPreview: View {
    let card: SidekickConversationEvent.CardReference
    @State private var expanded = false

    var body: some View {
        Button { expanded = true } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.65, green: 0.60, blue: 1)).frame(width: 3)
                VStack(alignment: .leading, spacing: 5) {
                    Label("Proactive suggestion", systemImage: "sparkles")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                    Text(card.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                    if !card.summary.isEmpty {
                        Text(card.summary).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(11)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View suggestion: \(card.title)")
        .popover(isPresented: $expanded, arrowEdge: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Proactive suggestion", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(card.title).font(.system(size: 19, weight: .semibold))
                    if !card.summary.isEmpty { Text(card.summary).font(.system(size: 13)).foregroundStyle(.secondary) }
                    if !card.recipient.isEmpty { Text("To: \(card.recipient)").font(.system(size: 12, weight: .medium)) }
                    if !card.content.isEmpty {
                        Divider()
                        Text(card.content).font(.system(size: 13)).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            .frame(width: 380).frame(maxHeight: 460)
            .preferredColorScheme(.dark)
        }
    }
}
