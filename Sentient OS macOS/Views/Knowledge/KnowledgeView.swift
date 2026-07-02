//
//  KnowledgeView.swift
//  Sentient OS macOS
//
//  The Knowledge window — a minimal Obsidian-style reader over the real markdown vault
//  (~/Sentient OS - Knowledge Base/). A two-pane split: a folder tree on the left (with a pinned
//  "Overview" = the root README, search, and disclosure folders), and a rendered-markdown reader
//  on the right. [[Wikilinks]] are clickable and jump between notes; a back/forward pair in the
//  reader bar walks the navigation history. Read-only — editing + the graph view come later.
//
//  This replaced the old DatabaseView (a dev CycleStore-summaries inspector, still reachable from
//  Dev Tools via SummariesView). Data: VaultTree.swift · rendering: MarkdownView.swift.
//  Doc: Documentation/Knowledge Viewer.md
//

import SwiftUI
import AppKit

struct KnowledgeView: View {
    /// Scene id for the standalone Knowledge window (opened via `openWindow`). Same string the old
    /// window used, so the app scene + the home's nav item wire up by type name alone.
    static let windowID = "knowledge"

    @State private var vault: KnowledgeVault?
    @State private var loaded = false
    @State private var selection: URL?
    @State private var expanded: Set<URL> = []
    @State private var search = ""

    // Navigation history (back / forward), so a wikilink jump can be undone.
    @State private var history: [URL] = []
    @State private var historyIndex = -1

    // The currently-open note's display content (title + body), recomputed on selection.
    @State private var note: (title: String, markdown: String)?

    // The markdown editor. `editing` swaps the rendered reader for a TextEditor over the RAW file
    // (frontmatter + H1 included — we edit the real bytes); `editText` is the live buffer and
    // `savedText` the last-committed copy (drift = unsaved edits). `syncing` is the mirror push in
    // flight; `mirrorEnabled` decides whether Save also syncs to the cloud MCP. `pendingNav` parks a
    // note-switch waiting on the unsaved-edits prompt.
    @State private var editing = false
    @State private var editText = ""
    @State private var savedText = ""
    @State private var syncing = false
    @State private var mirrorEnabled = false
    @State private var pendingNav: PendingNav?
    @State private var showDiscardPrompt = false
    @FocusState private var editorFocused: Bool

    /// A navigation parked behind the unsaved-edits prompt.
    private enum PendingNav { case open(URL), follow(URL), back }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 430)
        } detail: {
            reader
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
        .background(Theme.bg)
        .background(WindowChrome())   // transparent titlebar from launch (no "grey until resize")
        .task { await loadVault() }
        .alert("You have unsaved edits", isPresented: $showDiscardPrompt) {
            Button(mirrorEnabled ? "Save & Sync" : "Save") { promptSave() }
            Button("Discard", role: .destructive) { promptDiscard() }
            Button("Cancel", role: .cancel) { pendingNav = nil }
        } message: {
            Text("Save\(mirrorEnabled ? " and sync" : "") your changes to this note, or discard them?")
        }
    }

    private func loadVault() async {
        // A plain directory walk (~a handful of folders) — cheap enough to do inline on open.
        let v = KnowledgeVault.load()
        vault = v
        loaded = true
        mirrorEnabled = await MirrorClient.shared.isEnabled
        guard selection == nil else { return }
        if let r = v?.readme { open(r) }                          // greet with the portrait
        else if let first = v?.allNotes.first { open(first.url) }
    }

    // MARK: Navigation + a wikilink back-trail

    /// Back is offered ONLY after following a wikilink — browsing the tree starts a fresh trail.
    private var canGoBack: Bool { historyIndex > 0 }

    /// Open a note from the sidebar (or on first load): a clean start, so no Back button shows.
    private func open(_ url: URL) {
        history = [url]; historyIndex = 0
        select(url)
    }

    /// Follow a wikilink: push onto the trail (truncating anything we'd gone back past), so Back
    /// returns to the note we jumped from.
    private func follow(_ url: URL) {
        if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
        if history.last != url { history.append(url); historyIndex = history.count - 1 }
        select(url)
    }

    /// Read a note + reveal it in the tree (expand its ancestor folders). No history side-effects.
    private func select(_ url: URL) {
        selection = url
        note = KnowledgeVault.read(url)
        if let v = vault { expanded.formUnion(v.ancestors(of: url)) }
    }

    private func goBack() { guard canGoBack else { return }; historyIndex -= 1; select(history[historyIndex]) }

    // MARK: Navigation guards (never silently drop unsaved edits)

    /// Sidebar/initial selection, wikilink jumps, and Back all funnel through these. While editing
    /// with unsaved changes → park the target and raise the prompt; editing but clean → quietly leave
    /// edit mode and proceed; not editing → straight through.
    private func requestOpen(_ url: URL) {
        if editing { if isDirty { pendingNav = .open(url); showDiscardPrompt = true; return }; exitEdit() }
        open(url)
    }
    private func requestFollow(_ url: URL) {
        if editing { if isDirty { pendingNav = .follow(url); showDiscardPrompt = true; return }; exitEdit() }
        follow(url)
    }
    private func requestBack() {
        if editing { if isDirty { pendingNav = .back; showDiscardPrompt = true; return }; exitEdit() }
        goBack()
    }

    // MARK: The markdown editor

    private var isDirty: Bool { editing && editText != savedText }

    /// Enter edit mode over the RAW file (frontmatter + H1 included — we edit the real bytes, never a
    /// reconstruction). Refreshes whether the cloud mirror is on, so Save knows if it should sync.
    private func beginEdit() {
        guard let url = selection else { return }
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? (note?.markdown ?? "")
        editText = raw; savedText = raw
        editing = true
        VaultActivity.shared.editorBusy = true
        Task { mirrorEnabled = await MirrorClient.shared.isEnabled }
    }

    /// Esc — cancel editing. Dirty → prompt (no parked nav, so Save/Discard just settle in place);
    /// clean → leave edit mode.
    private func cancelEdit() {
        guard editing else { return }
        if isDirty { pendingNav = nil; showDiscardPrompt = true } else { exitEdit() }
    }

    /// Commit the buffer to disk and (if the mirror is on) sync the whole vault to the cloud MCP, then
    /// leave edit mode. No changes → just leave (no needless write/sync). `completion` runs once the
    /// save+sync settles — the unsaved-edits prompt uses it to continue a parked note-switch.
    private func save(then completion: (() -> Void)? = nil) {
        guard editing, let url = selection else { completion?(); return }
        guard editText != savedText else { exitEdit(); completion?(); return }
        do {
            try editText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log("Knowledge editor: save failed — \(error.localizedDescription)")
            return   // stay in edit mode so the user's text isn't lost
        }
        savedText = editText
        note = KnowledgeVault.read(url)            // refresh the rendered view behind us
        VaultActivity.shared.vaultDirty = true     // a vault change is now pending a mirror push

        guard mirrorEnabled else { exitEdit(); completion?(); return }

        syncing = true
        Task {   // inherits the main actor; state writes after the await are safe
            var ok = true
            do { try await MirrorClient.shared.push() }
            catch { ok = false; Log("Knowledge editor: sync failed — \((error as? LocalizedError)?.errorDescription ?? "\(error)")") }
            if ok { VaultActivity.shared.vaultDirty = false }   // else stays dirty → pushIfDirty retries later
            syncing = false
            exitEdit()
            completion?()
        }
    }

    private func exitEdit() {
        editing = false
        VaultActivity.shared.editorBusy = false
    }

    // The unsaved-edits prompt's three answers.
    private func promptSave()    { save { performPendingNav() } }
    private func promptDiscard() { exitEdit(); performPendingNav() }
    private func performPendingNav() {
        guard let p = pendingNav else { return }
        pendingNav = nil
        switch p {
        case .open(let u):   open(u)
        case .follow(let u): follow(u)
        case .back:          goBack()
        }
    }

    private var searchResults: [VaultNode] {
        guard let v = vault, !search.isEmpty else { return [] }
        return v.allNotes.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            searchField
            ScrollView { sidebarList }
        }
        .background(Theme.panel)   // subtle elevated chrome — distinct from the black reading pane
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                OrbMark(size: 15)
                Text("Knowledge").font(.system(size: 22, design: .serif)).italic().foregroundStyle(.white)
            }
            MonoCaps(subtitle, size: 8.5, tracking: 2, color: Theme.Ink.deepMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
    }

    private var subtitle: String {
        guard let v = vault else { return "Private · on this Mac" }
        let n = v.titleIndex.count
        return "\(n) note\(n == 1 ? "" : "s") · private to this Mac"
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.faint)
            TextField("Search notes", text: $search)
                .textFieldStyle(.plain).foregroundStyle(.white).font(.system(size: 13))
                .tint(Theme.knowledgeAccent)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.faint)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .glassCard(radius: 9)
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    @ViewBuilder
    private var sidebarList: some View {
        // A plain VStack (NOT Lazy): the tree is small, and LazyVStack mangles disclosure
        // insert/remove transitions (children fly the wrong way / too far). A real VStack reflows
        // cleanly, so the clipped accordion in NodeRow reads right. Don't "optimize" this back.
        VStack(alignment: .leading, spacing: 1) {
            if search.isEmpty {
                if let readme = vault?.readme {
                    OverviewRow(selected: selection == readme) { requestOpen(readme) }
                }
                ForEach(vault?.nodes ?? []) { node in
                    NodeRow(node: node, depth: 0, expanded: $expanded,
                            selection: selection, onSelect: { requestOpen($0) })
                }
            } else if searchResults.isEmpty {
                Text("No matches").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 12).padding(.top, 14)
            } else {
                ForEach(searchResults) { node in
                    NoteRow(title: node.name, depth: 0, selected: node.url == selection) {
                        requestOpen(node.url)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
    }

    // MARK: Reader

    private var reader: some View {
        readerContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
            .toolbar {
                // The actions live in the window's titlebar (no extra row): Back rides in on the left
                // only after a wikilink jump; Edit + Reveal in Finder sit TOGETHER at the top-right.
                // (One ToolbarItemGroup, not two ToolbarItems — split-view detail toolbars left-align
                // multiple separate .primaryAction items; a single group trails correctly.)
                if canGoBack {
                    ToolbarItem(placement: .navigation) {
                        Button(action: requestBack) { Label("Back", systemImage: "chevron.left") }
                            .help("Back")
                    }
                }
                if selection != nil {
                    ToolbarItemGroup(placement: .primaryAction) {
                        editToolbarItem
                        revealToolbarButton
                    }
                }
            }
    }

    @ViewBuilder
    private var revealToolbarButton: some View {
        if let url = selection {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .labelStyle(.titleAndIcon)
            .help("Reveal in Finder")
        }
    }

    /// The Edit ⟷ Save toggle in the titlebar (left of Reveal in Finder). In edit mode it commits and,
    /// if the user mirrors to the cloud MCP, syncs — showing a spinner while that push is in flight.
    @ViewBuilder
    private var editToolbarItem: some View {
        if syncing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Syncing").font(.system(size: 12))
            }
            .foregroundStyle(Theme.secondary)
        } else if editing {
            Button { save() } label: {
                Label(mirrorEnabled ? "Save & Sync to Cloud MCP" : "Save", systemImage: "checkmark")
            }
            .labelStyle(.titleAndIcon)
        } else {
            Button { beginEdit() } label: { Label("Edit", systemImage: "square.and.pencil") }
                .labelStyle(.titleAndIcon)
                .help("Edit this note")
        }
    }

    @ViewBuilder
    private var readerContent: some View {
        if editing, let url = selection {
            editorView(url)
        } else if let note, let url = selection {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id("top")
                        MonoCaps(url.lastPathComponent, size: 9, tracking: 2, color: Theme.Ink.deepMuted)
                            .lineLimit(1).truncationMode(.middle)
                            .padding(.bottom, 11)
                        Text(note.title)
                            .font(.system(size: 30, design: .serif)).foregroundStyle(.white)
                            .textSelection(.enabled)
                            .padding(.bottom, 22)
                        MarkdownView(markdown: note.markdown,
                                     exists: { vault?.resolve($0) != nil },
                                     onNavigate: { title in if let u = vault?.resolve(title) { requestFollow(u) } },
                                     onExternal: { NSWorkspace.shared.open($0) })
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 46).padding(.top, 18).padding(.bottom, 90)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onChange(of: selection) { _, _ in proxy.scrollTo("top", anchor: .top) }
            }
        } else if loaded && vault == nil {
            emptyState(title: "No knowledge base yet",
                       subtitle: "Once Sentient has read your life, your private knowledge base shows up here.")
        } else if loaded {
            emptyState(title: "Select a note", subtitle: nil)
        } else {
            Color.clear   // pre-load: no flash
        }
    }

    /// Edit mode — a plain-text editor over the raw markdown, in the same reading column so the swap
    /// feels in place. Wikilinks/headers show as their literal source here (you're editing the file).
    /// Esc cancels (prompting if there are unsaved changes).
    private func editorView(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoCaps(url.lastPathComponent, size: 9, tracking: 2, color: Theme.Ink.deepMuted)
                .lineLimit(1).truncationMode(.middle)
                .padding(.bottom, 12)
            TextEditor(text: $editText)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.92))
                .tint(Theme.knowledgeAccent)
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, 44).padding(.top, 18).padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { editorFocused = true }
        .onExitCommand { cancelEdit() }
    }

    private func emptyState(title: String, subtitle: String?) -> some View {
        VStack(spacing: 14) {
            Orb(size: 92)
            Text(title).font(.system(size: 20, design: .serif).italic()).foregroundStyle(Theme.Ink.statusInk)
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar rows

/// The pinned root README, shown as "Overview" with the brand orb glyph.
private struct OverviewRow: View {
    let selected: Bool
    let onSelect: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                OrbMark(size: 13)
                Text("Overview")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(selected ? Theme.knowledgeAccent : .white.opacity(0.85))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(rowBackground(selected: selected, hover: hover))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.bottom, 4)
    }
}

/// A folder row: a chevron + folder glyph that toggles its disclosure.
private struct FolderRow: View {
    let name: String
    let depth: Int
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
                    .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 10)
                Image(systemName: isOpen ? "folder.fill" : "folder")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.secondary).frame(width: 14)
                Text(name)
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).padding(.trailing, 8)
            .padding(.leading, CGFloat(depth) * 14 + 8)
            .background(rowBackground(selected: false, hover: hover))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A note (leaf) row: a doc glyph + title, accent when selected.
private struct NoteRow: View {
    let title: String
    let depth: Int
    let selected: Bool
    let onSelect: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                Color.clear.frame(width: 10)   // align note titles under folder names
                Image(systemName: "doc.text")
                    .font(.system(size: 10.5)).foregroundStyle(selected ? Theme.knowledgeAccent : Theme.faint)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? Theme.knowledgeAccent : .white.opacity(0.72))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).padding(.trailing, 8)
            .padding(.leading, CGFloat(depth) * 14 + 8)
            .background(rowBackground(selected: selected, hover: hover))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Recursive tree node: a folder (its header + a clipped, accordion-collapsing children block) or
/// a note leaf.
private struct NodeRow: View {
    let node: VaultNode
    let depth: Int
    @Binding var expanded: Set<URL>
    let selection: URL?
    let onSelect: (URL) -> Void

    private var isOpen: Bool { expanded.contains(node.url) }

    var body: some View {
        if node.isFolder {
            VStack(alignment: .leading, spacing: 1) {
                FolderRow(name: node.name, depth: depth, isOpen: isOpen) {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        if isOpen { expanded.remove(node.url) } else { expanded.insert(node.url) }
                    }
                }
                // The clip WINDOW sits BELOW the header (the FolderRow is outside it), so the
                // accordion slides/fades only in the region beneath the folder line — the children
                // retract into that line and never ride up over the folder's name.
                VStack(alignment: .leading, spacing: 1) {
                    if isOpen {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(node.children) { child in
                                NodeRow(node: child, depth: depth + 1, expanded: $expanded,
                                        selection: selection, onSelect: onSelect)
                            }
                        }
                        .transition(.accordion)
                    }
                }
                .clipped()
            }
        } else {
            NoteRow(title: node.name, depth: depth, selected: node.url == selection) {
                onSelect(node.url)
            }
        }
    }
}

// MARK: - The accordion transition (slide up + exponential fade)

private extension AnyTransition {
    /// The disclosed-children transition: the block slides up into the header (`.move`) AND its
    /// opacity rides an exponential curve — so it's far more invisible the nearer it sits to the
    /// collapsed ("unexpanded") position, only reading as solid once it's well open, and dissolving
    /// fast as it retracts. (Opacity is decoupled from the slide so it can have its own curve.)
    static var accordion: AnyTransition {
        .move(edge: .top).combined(with: .modifier(
            active:   ExponentialFade(expansion: 0),
            identity: ExponentialFade(expansion: 1)))
    }
}

/// Opacity as an exponential function of how-open the block is (0 = collapsed, 1 = expanded).
/// Animatable, so SwiftUI interpolates `expansion` across the disclosure and we map it through the
/// curve every frame — making opacity ∝ exp(expansion) rather than linear.
private struct ExponentialFade: ViewModifier, Animatable {
    var expansion: Double
    var animatableData: Double {
        get { expansion }
        set { expansion = newValue }
    }
    func body(content: Content) -> some View {
        let c = 3.0                                   // curve strength — higher = more invisible near collapsed
        let x = max(0, min(1, expansion))
        let opacity = (exp(c * x) - 1) / (exp(c) - 1) // 0 at collapsed, 1 at open, convex between
        return content.opacity(opacity)
    }
}

// MARK: - Shared row chrome

private func rowBackground(selected: Bool, hover: Bool) -> some View {
    RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(selected ? Theme.knowledgeAccent.opacity(0.15) : (hover ? Color.white.opacity(0.05) : .clear))
}

// MARK: - Window chrome

/// Grabs the hosting NSWindow and makes its titlebar transparent (dark, unified with the OLED
/// content) from launch. Without this, a SwiftUI window with a toolbar renders an opaque GREY
/// titlebar until the first window resize forces a relayout — this applies the final look up front.
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }
    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
    }
}

#Preview("Knowledge") {
    KnowledgeView().frame(width: 1100, height: 720).preferredColorScheme(.dark)
}
