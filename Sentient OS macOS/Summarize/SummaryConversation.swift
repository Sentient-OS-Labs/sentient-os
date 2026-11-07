import AppKit
@preconcurrency import ApplicationServices

/// App-specific boundaries over a read-only AX snapshot. Browsers retain whole-page capture.
nonisolated enum SummaryConversation {
    enum App: String { case whatsapp = "net.whatsapp.WhatsApp", messages = "com.apple.MobileSMS"
        case claude = "com.anthropic.claudefordesktop", chatgpt = "com.openai.codex"
        case slack = "com.tinyspeck.slackmacgap"
    }
    struct Node {
        var parent: Int
        var role: String
        var id = ""
        var classes: [String] = []
        var description = ""
        var value = ""
        var frame: CGRect?
        var title = ""
        var subrole = ""
        var domID = ""
    }
    struct Item {
        var text: String
        var anchor: String
        var frame: CGRect?
        var message = true
        var visibleContent: Bool? = nil
        var identity = ""
    }
    struct Selection {
        var title: String
        var items: [Item]
        var viewport: CGRect
        var offscreen: Int
        var text: String { items.map(\.text).joined(separator: "\n") }
    }

    static func read(window: AXUIElement, app: App, application: String) throws -> SummarySource {
        let began = Date()
        var nodes: [Node] = [], pending: [(AXUIElement, Int)] = [(window, -1)]
        var seen: [UInt: [AXUIElement]] = [:], bytes = 0, limited = false
        while let (element, parent) = pending.popLast() {
            try Task.checkCancellation()
            if nodes.count >= 8_000 || bytes > 400_000 || Date().timeIntervalSince(began) > 5 { limited = true; break }
            let hash = CFHash(element)
            if seen[hash]?.contains(where: { CFEqual($0, element) }) == true { continue }
            seen[hash, default: []].append(element)
            AXUIElementSetMessagingTimeout(element, 0.06)
            let role = string(element, "AXRole")
            if ["AXToolbar", "AXMenuBar", "AXMenu"].contains(role) || string(element, "AXSubrole") == "AXSecureTextField"
                || (attribute(element, "AXProtectedContent") as? Bool) == true { continue }
            let native = app == .whatsapp || app == .messages
            let description = string(element, "AXDescription")
            let value = ["AXStaticText", "AXTextArea", "AXHeading", "AXLink"].contains(role) ? string(element, "AXValue") : ""
            let index = nodes.count
            nodes.append(Node(parent: parent, role: role, id: string(element, "AXIdentifier"),
                classes: native ? [] : (attribute(element, "AXDOMClassList") as? [String] ?? []),
                description: description, value: value, frame: SummaryAccessibility.rect(element),
                title: string(element,"AXTitle"),subrole:string(element,"AXSubrole"),domID:string(element,"AXDOMIdentifier")))
            bytes += description.utf8.count + value.utf8.count
            let children = attribute(element, "AXChildren") as? [AXUIElement] ?? []
            let available = max(0, 8_000 - nodes.count - pending.count)
            if children.count > available { limited = true }
            pending += children.prefix(available).reversed().map { ($0, index) }
        }
        guard let selection = select(nodes, app: app) else { throw SummaryAccessibility.Failure.unavailable }
        // Slack virtualizes unloaded history. Until a continuation source is available,
        // report this capture as excerpts rather than implying it reaches the channel's end.
        if app == .slack { limited = true }
        var text = selection.text
        var localExtension = false
        if app == .whatsapp || app == .messages,
           let extra = SummaryConversationStore.newerMessages(app: app, title: selection.title, items: selection.items), !extra.lines.isEmpty {
            text += "\n" + extra.lines.joined(separator: "\n")
            limited = limited || extra.truncated
            localExtension = true
        }
        let scope = "current conversation, whole first visible message onward"
        return SummarySource(text: SummaryAccessibility.bounded(text, maximumBytes: SummaryAccessibility.maximumTextBytes),
            title: String(selection.title.prefix(250)), application: application,
            truncated: limited || text.utf8.count > SummaryAccessibility.maximumTextBytes,
            scope: scope + (localExtension ? "; includes newer messages from the same local chat" : "; includes newer loaded messages"),
            offscreenTextElements: selection.offscreen)
    }

    static func select(_ nodes: [Node], app: App) -> Selection? {
        func descendant(_ index: Int, of ancestor: Int) -> Bool {
            var p = index
            while p >= 0 && p < nodes.count { if p == ancestor { return true }; p = nodes[p].parent }
            return false
        }
        let root: Int?
        switch app {
        case .whatsapp: root = nodes.firstIndex { $0.id == "ChatMessagesTableView" }
        case .messages: root = nodes.firstIndex { $0.id == "TranscriptCollectionView" }
        case .claude: root = nodes.firstIndex { $0.classes.contains("epitaxy-chat-panel-body") }
        case .chatgpt: root = nodes.firstIndex { $0.classes.contains("thread-scroll-container") && $0.description == "Conversation" }
        case .slack: root = nodes.firstIndex { $0.classes.contains("p-message_pane") }
        }
        guard let root, var viewport = nodes[root].frame, viewport.height > 1 else { return nil }
        var title = app == .whatsapp ? "WhatsApp conversation" : app == .messages ? "Messages conversation" : app == .claude ? "Claude conversation" : app == .slack ? "Slack conversation" : "ChatGPT conversation"
        if app == .slack, let list = nodes.indices.first(where: { descendant($0,of:root) && nodes[$0].role == "AXList" && !nodes[$0].description.isEmpty }) { title = nodes[list].description }
        if let header = nodes.first(where: { $0.id == (app == .whatsapp ? "NavigationBar_HeaderViewButton" : "ConversationTitle") }),
           app == .whatsapp || app == .messages {
            title = header.description
            if let frame = header.frame {
                let top = max(viewport.minY, frame.maxY + 8)
                viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
            }
        }
        if let composer = nodes.first(where: { $0.id == (app == .whatsapp ? "ChatBar_ComposerTextView" : "MessageEntryView") }),
           let frame = composer.frame, app == .whatsapp || app == .messages {
            viewport.size.height = max(0, min(viewport.maxY, frame.minY - 4) - viewport.minY)
        }
        var items: [Item] = []
        if app == .whatsapp {
            for n in nodes.indices where descendant(n, of: root) && n != root {
                let node = nodes[n]
                if node.id == "WAMessageBubbleTableViewCell", !node.description.isEmpty {
                    items.append(Item(text: clean(node.description), anchor: clean(node.description), frame: node.frame))
                } else if node.role == "AXHeading", !node.description.isEmpty {
                    items.append(Item(text: clean(node.description), anchor: "", frame: node.frame, message: false))
                }
            }
        } else if app == .messages {
            for n in nodes.indices where nodes[n].parent == root {
                let node = nodes[n]
                if !node.description.isEmpty {
                    let body = nodes.indices.first { descendant($0, of: n) && nodes[$0].id == "CKBalloonTextView" }.map { nodes[$0].value } ?? ""
                    items.append(Item(text: clean(node.description), anchor: clean(body), frame: node.frame))
                } else if let label = nodes.indices.first(where: { descendant($0, of: n) && nodes[$0].role == "AXStaticText" && !nodes[$0].description.isEmpty }) {
                    items.append(Item(text: clean(nodes[label].description), anchor: "", frame: nodes[label].frame, message: false))
                }
            }
        } else {
            func frameVisible(_ frame: CGRect?) -> Bool {
                guard let frame, frame.height > 1, frame.width > 1 else { return false }
                let intersection = frame.intersection(viewport)
                return !intersection.isNull && intersection.height > 1 && intersection.width > 1
            }
            var groupOrder: [Int] = [], grouped: [Int:[Int]] = [:], labels: [Int:String] = [:]
            var chatGPTMessage: Int?
            for n in nodes.indices where descendant(n, of: root) {
                let node = nodes[n]
                if app == .chatgpt, node.role == "AXHeading", node.classes.contains("sr-only"),
                   node.title == "You said:" || node.title == "ChatGPT said:" {
                    chatGPTMessage = n; labels[n] = node.title
                }
                guard ["AXStaticText", "AXTextArea", "AXLink"].contains(node.role) else { continue }
                let text = node.value.isEmpty ? node.title : node.value
                guard !clean(text).isEmpty else { continue }
                if node.role == "AXLink", nodes.contains(where: { $0.parent == n && $0.role == "AXStaticText" }) { continue }
                var p = n, excluded = false
                var owner: Int? = app == .chatgpt ? chatGPTMessage : nil
                while p != root && p >= 0 {
                    let ancestor = nodes[p]
                    if app == .claude, ancestor.subrole == "AXDocumentArticle", owner == nil { owner = p; labels[p] = ancestor.description }
                    if app == .slack, ancestor.classes.contains("c-message_kit__hover"), owner == nil { owner = p }
                    if (ancestor.classes.contains("sr-only") && app != .slack) || ancestor.role == "AXButton" || ancestor.role == "AXPopUpButton"
                        || ancestor.classes.contains("c-message_kit__reaction_bar") || ancestor.classes.contains("c-timestamp")
                        || ancestor.classes.contains("group/agent-activity") || ancestor.classes.contains("group/activity-header")
                        || ancestor.classes.contains("group/status")
                        || ancestor.classes.contains("group/turn-diff-header") || ancestor.classes.contains("ProseMirror") { excluded = true; break }
                    p = ancestor.parent
                }
                if !excluded, let owner {
                    if grouped[owner] == nil { groupOrder.append(owner) }
                    grouped[owner,default:[]].append(n)
                }
            }
            for owner in groupOrder {
                let content = grouped[owner] ?? []
                let text = content.map { clean(nodes[$0].value.isEmpty ? nodes[$0].title : nodes[$0].value) }.joined(separator:"\n")
                var label = labels[owner] ?? ""
                if app == .claude {
                    let heading = nodes.indices.first { descendant($0,of:owner) && nodes[$0].role == "AXHeading" && nodes[$0].classes.contains("sr-only") }
                    label = heading.map { nodes[$0].title.hasPrefix("You said:") ? "You:" : "Claude:" } ?? "Claude:"
                } else if app == .slack {
                    let sender = nodes.indices.first { descendant($0,of:owner) && nodes[$0].classes.contains("c-message__sender_button") }.map { nodes[$0].title } ?? ""
                    let time = nodes.indices.first { descendant($0,of:owner) && nodes[$0].classes.contains("c-timestamp") }.map { nodes[$0].title } ?? ""
                    label = [sender,time].filter { !$0.isEmpty }.joined(separator:" · ")
                }
                let identity = app == .slack && nodes[owner].parent >= 0 ? nodes[nodes[owner].parent].domID : ""
                items.append(Item(text:label.isEmpty ? text : label + "\n" + text,anchor:text,frame:nodes[owner].frame,
                                  visibleContent:content.contains { frameVisible(nodes[$0].frame) },identity:identity))
            }
        }
        func visible(_ item: Item) -> Bool {
            if let visibleContent = item.visibleContent { return visibleContent }
            guard let frame = item.frame, frame.height > 1, frame.width > 1 else { return false }
            return frame.intersection(viewport).height > 1 && frame.intersection(viewport).width > 1
        }
        guard let start = items.firstIndex(where: { $0.message && visible($0) }) else { return nil }
        let selected = Array(items[start...])
        guard selected.contains(where: { $0.message }) else { return nil }
        return Selection(title: title, items: selected, viewport: viewport,
                         offscreen: selected.filter { $0.message && !visible($0) }.count)
    }
    static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter { ![0x200E,0x200F,0x202A,0x202B,0x202C,0x2066,0x2067,0x2068,0x2069].contains($0.value) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
