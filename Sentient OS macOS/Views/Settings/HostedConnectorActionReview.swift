// Exceptional recovery for an external action whose final response was lost.
// Only the signed-in account owner can clear the hold; reviewing never resends the action.
// Doc: Documentation - Settings.md
import SwiftUI

struct HostedConnectorActionReview: View {
    let account: HostedConnectorAccount
    let client: HostedConnectorClient
    @State private var actions: [HostedConnectorClient.UncertainAction] = []
    @State private var reviewing: HostedConnectorClient.UncertainAction?
    @State private var showReview = false
    @State private var busy = false
    @State private var message: String?
    @State private var loadFailed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(actions) { action in
                Text("An action needs your review.").font(.system(size: 12, weight: .medium))
                Text("\(action.tool.replacingOccurrences(of: "_", with: " ").capitalized) · \(time(action.created_at))")
                    .font(.system(size: 10)).foregroundStyle(Theme.Ink.body)
                Button("I checked the service…") { reviewing = action; showReview = true }
                    .buttonStyle(.plain).font(.system(size: 11)).disabled(busy)
            }
            if let message { Text(message).font(.system(size: 10)).foregroundStyle(Theme.Ink.body) }
            if loadFailed { Button("Retry action check") { Task { await load() } }.buttonStyle(.plain).font(.system(size: 11)) }
        }
        .foregroundStyle(Theme.Ink.bright)
        .task(id: account.taskTarget) { await load() }
        .confirmationDialog("What happened in the service?", isPresented: $showReview, titleVisibility: .visible) {
            Button("It completed; mark reviewed") { resolve(allowRetry: false) }
            Button("Allow a new attempt") { resolve(allowRetry: true) }
            Button("Keep waiting", role: .cancel) {}
        } message: {
            Text("Sentient lost the final response and has paused further sends and creates for this account. Check the service first. The original action might still complete. Reviewing never repeats it automatically.")
        }
    }
    private func load() async {
        do { actions = try await client.uncertainActions(account); message = nil; loadFailed = false }
        catch { message = "Unfinished actions could not be checked. Your saved reading choice is unchanged."; loadFailed = true }
    }
    private func resolve(allowRetry: Bool) {
        guard let reviewing else { return }; busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await client.resolve(reviewing, account: account, allowRetry: allowRetry)
                actions = try await client.uncertainActions(account)
                message = "Reviewed. Start a new task if more work is needed."
            } catch { message = (error as? LocalizedError)?.errorDescription ?? "The review could not be saved. Try again." }
        }
    }
    private func time(_ value: String) -> String {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (parser.date(from: value) ?? ISO8601DateFormatter().date(from: value))?.formatted(date: .abbreviated, time: .shortened) ?? "recently"
    }
}
