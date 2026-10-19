// Selected local sources and their connector adapters, shared by every analysis entry.
// Doc: Documentation - Ingestion Pipeline.md

import Foundation

/// One thing the user picked to analyze — a file root or a database/chat source. `RunSource` is the
/// selection model (the dev picker + the home satellites speak it); `connectors(from:)` turns a
/// selection into the iterative-core connectors both run paths share.
enum RunSource: Hashable {
    case files(FileRoot)
    case whatsapp(chatJIDs: Set<String>)    // the opt-in chats to analyze
    case imessage(chatGUIDs: Set<String>)   // the opt-in chats to analyze
    case notes                              // all notes (newest-1000 cap inside the source)
    case siyuan                             // every open notebook selected by the user
    case appleMail(accounts: Set<String>)
    case appleCalendar(calendarIDs: Set<String>)

    var label: String {
        switch self {
        case .files(let root): return root.label
        case .whatsapp:        return "WhatsApp"
        case .imessage:        return "iMessage"
        case .notes:           return "Apple Notes"
        case .siyuan:          return "SiYuan"
        case .appleMail:       return "Apple Mail"
        case .appleCalendar:   return "Apple Calendar"
        }
    }

    /// Map a source selection to the iterative-core connectors. File roots collapse into ONE
    /// FilesConnector (it pages each root itself); chats/Notes each become their own connector.
    /// Shared by the home "Analyze Now" and the dev "start on device" buttons so both run the exact
    /// same engine over the same picks.
    static func connectors(from sources: [RunSource]) -> [any Connector] {
        let roots: [FileRoot] = sources.compactMap { if case .files(let r) = $0 { return r } else { return nil } }
        var connectors: [any Connector] = roots.isEmpty ? [] : [FilesConnector(roots: roots)]
        for s in sources {
            switch s {
            case .whatsapp(let jids):  connectors.append(WhatsAppConnector(chatJIDs: jids))
            case .imessage(let guids): connectors.append(iMessageConnector(chatGUIDs: guids))
            case .notes:               connectors.append(NotesConnector())
            case .siyuan:              connectors.append(SiYuanConnector())
            case .appleMail(let accounts): connectors.append(AppleMailConnector(accounts: accounts))
            case .appleCalendar(let ids): connectors.append(AppleCalendarConnector(calendarIDs: ids))
            case .files:               break   // rolled into FilesConnector(roots:)
            }
        }
        return connectors
    }
}
