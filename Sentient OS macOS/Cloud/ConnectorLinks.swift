//
// ConnectorLinks.swift
// Provider-specific setup pages for hosted sources. Both source sheets use this mapping;
// unknown apps fall back to the provider's directory. Verified in both directories 2026-09-28.
// Doc: ../Views/Settings/Documentation - Settings.md
//

import Foundation

nonisolated enum ConnectorLinks {
    static func directory(for backend: ModelBackend = .current) -> URL {
        URL(string: backend == .claude
            ? "https://claude.ai/customize/connectors"
            : "https://chatgpt.com/plugins")!
    }

    static func page(for slug: String, backend: ModelBackend = .current) -> URL {
        let page: String
        if backend == .claude {
            switch slug {
            case "gmail": page = "gmail-gmailmcp"
            case "google-calendar": page = "google-calendar-calendarmcp"
            case "google-drive": page = "google-drive-drivemcp"
            case "slack": page = "slack"
            // Claude exposes both logical Outlook sources through one work/school connector.
            case "outlook-mail", "outlook-email", "outlook-calendar": page = "microsoft-365"
            default: return directory(for: backend)
            }
            return directory(for: backend).appendingPathComponent("id").appendingPathComponent(page)
        }

        switch slug {
        case "gmail": page = "plugin_connector_1p_95d39881713c8191931482a62d6edff9"
        case "google-calendar": page = "plugin_connector_1p_f8509de903288191b14a160c6c5d20b0"
        case "google-drive": page = "plugin_connector_1p_ab21a553bfbc81919ea8fd1858e3ffa7"
        case "slack": page = "plugin_asdk_app_69a1d78e929881919bba0dbda1f6436d"
        case "outlook-mail", "outlook-email": page = "plugin_connector_1p_6bcb5879c73c819196abc70016166099"
        case "outlook-calendar": page = "plugin_connector_1p_fd0f4f41caa88191a9456514bbffa06d"
        default: return directory(for: backend)
        }
        return directory(for: backend).appendingPathComponent(page)
    }
}
