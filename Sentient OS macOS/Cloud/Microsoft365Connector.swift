//
// Microsoft365Connector.swift
// One physical Microsoft 365 connection serves independently curated Mail and Calendar
// services. Owns their shared hosted identity and complete reviewed suite inventory.
// Doc: Documentation - Cloud - ClaudeCLI (the claude -p engine).md
//

import Foundation

nonisolated enum Microsoft365Connector {
    static let name = "Microsoft 365"
    static let url = "https://microsoft365.mcp.claude.com/mcp"
    static let prefix = "mcp__claude_ai_Microsoft_365__"
    static func contains(_ slug: String) -> Bool { ["outlook-mail", "outlook-calendar"].contains(slug) }

    static func denied(except allowed: [String]) -> [String] {
        let allowed = Set(allowed)
        return categories.keys.map { prefix + $0 }.filter { !allowed.contains($0) }.sorted()
    }

    /// Complete Microsoft 365 inventory checked against CLI 2.1.270. New names or changed
    /// verdicts refuse action attachment until reviewed; allowed mail actions remain a subset.
    static let categories: [String: ConnectorRegistry.ToolCategory] = [
        "chat_message_search": .read,
        "find_meeting_availability": .read,
        "get_granted_scopes": .read,
        "get_me": .read,
        "outlook_batch_delete_messages": .destructive,
        "outlook_batch_modify_labels": .write,
        "outlook_calendar_search": .read,
        "outlook_create_draft": .write,
        "outlook_create_event": .write,
        "outlook_create_filter": .write,
        "outlook_create_label": .write,
        "outlook_create_reply_all_draft": .write,
        "outlook_create_reply_draft": .write,
        "outlook_delete_draft": .destructive,
        "outlook_delete_event": .destructive,
        "outlook_delete_filter": .destructive,
        "outlook_delete_label": .destructive,
        "outlook_email_search": .read,
        "outlook_find_available_time": .read,
        "outlook_forward_mail": .write,
        "outlook_modify_labels": .write,
        "outlook_modify_thread_labels": .write,
        "outlook_respond_to_event": .destructive,
        "outlook_send_draft": .write,
        "outlook_send_mail": .write,
        "outlook_set_vacation": .write,
        "outlook_trash_thread": .destructive,
        "outlook_untrash_thread": .write,
        "outlook_update_draft": .destructive,
        "outlook_update_event": .destructive,
        "outlook_update_label": .write,
        "read_resource": .read,
        "search_people": .read,
        "sharepoint_copy_item": .write,
        "sharepoint_create_folder": .write,
        "sharepoint_delete_item": .destructive,
        "sharepoint_folder_search": .read,
        "sharepoint_move_item": .write,
        "sharepoint_rename_item": .write,
        "sharepoint_search": .read,
        "sharepoint_update_file": .destructive,
        "sharepoint_upload_file": .destructive,
        "teams_create_chat": .write,
        "teams_list_channel_messages": .read,
        "teams_list_channels": .read,
        "teams_list_chats": .read,
        "teams_list_teams": .read,
        "teams_reply_channel_message": .write,
        "teams_send_channel_message": .write,
        "teams_send_chat_message": .write,
    ]
    static func validateClassification(_ tools: [ConnectorRegistry.ClassifiedTool]) throws {
        let expected = Dictionary(uniqueKeysWithValues: categories.map { (prefix + $0.key, $0.value) })
        guard tools.count == expected.count, Set(tools.map(\.name)).count == tools.count,
              tools.allSatisfy({ expected[$0.name] == $0.category }) else {
            throw MCPSource.MCPError.invalidResponse(slug: OutlookMailConnector.slug, rule: "microsoft365_classification")
        }
    }

}
