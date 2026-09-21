// ConnectorCaution.swift
// Persists the connector warnings from the last completed knowledge-base pass. The home uses
// the existing caution capsule; dismissing one warning reveals the next without probing a source.
// Doc: Documentation - System (Permissions, Health, Uninstall).md

import Foundation

enum ConnectorCaution {
    // The connector namespace is also cleared by FactoryReset.
    static let key = "mcp.readCautions"

    struct Item: Codable, Equatable, Identifiable {
        let slug: String
        let name: String
        var id: String { slug }
        var message: String {
            "\(name) was not connected properly, so Sentient couldn't process it. You can reconnect in Settings"
        }
    }

    static func items(from data: Data) -> [Item] {
        (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    /// Called only once the KB step finishes, including a successful no-op. Snapshot names
    /// so an account removed later still has a readable warning. An empty result clears it.
    @discardableResult
    static func record(_ slugs: Set<String>, defaults: UserDefaults = .standard) -> [Item] {
        let items = slugs.sorted().map { Item(slug: $0, name: ConnectorRegistry.displayName(slug: $0)) }
        save(items, defaults: defaults)
        return items
    }

    static func dismiss(_ slug: String, defaults: UserDefaults = .standard) {
        let remaining = items(from: defaults.data(forKey: key) ?? Data()).filter { $0.slug != slug }
        save(remaining, defaults: defaults)
    }

    private static func save(_ items: [Item], defaults: UserDefaults) {
        if items.isEmpty { defaults.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: key) }
    }
}
