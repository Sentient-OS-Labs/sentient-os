//
//  KnowledgeView.swift
//  Sentient OS macOS
//
//  The Knowledge window — a minimal Obsidian-style reader / editor / manager over the real markdown
//  vault (~/Sentient OS - Knowledge Base/). Two-pane split: a folder tree (pinned "Overview" = the
//  root README, search, disclosure folders; create via the header "+", a folder-hover "+", or
//  right-click) and a rendered-markdown reader on the right. [[Wikilinks]] jump between notes (Back walks the trail);
//  the titlebar carries Edit / Delete (→ Trash) / Reveal in Finder. Every edit/create/delete commits
//  locally and DEBOUNCE-syncs to the cloud MCP (VaultActivity.markChanged → the sidebar status line).
//  The window OPENS in the "Constellation View" graph (Graph/NightSkyView.swift — the default);
//  native SkyDoor toolbar buttons swap between it and the reader (sky: top-center · reader:
//  top-left; ⌘⇧G). Click a star to read that note; Back (or Esc) returns to the sky where you left it.
//
//  Replaced the old DatabaseView (a dev CycleStore-summaries inspector, still in Dev Tools via
//  SummariesView). Data: VaultTree.swift · rendering: MarkdownView.swift.
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
    // `savedText` the last-committed copy (drift = unsaved edits). `mirrorEnabled` gates the header's
    // sync-status line. `pendingNav` parks a note-switch waiting on the unsaved-edits prompt.
    @State private var editing = false
    @State private var editText = ""
    @State private var savedText = ""
    @State private var mirrorEnabled = false
    @State private var pendingNav: PendingNav?
    @State private var showDiscardPrompt = false
    @FocusState private var editorFocused: Bool
    @FocusState private var searchFocused: Bool
    @FocusState private var createFieldFocused: Bool

    // The new-note / new-folder name prompt (raised by the right-click menus).
    @State private var showCreatePrompt = false
    @State private var createIsFolder = false
    @State private var createParent: URL?     // nil = the vault root
    @State private var createName = ""

    // The Night Sky graph view — the window OPENS here (Constellation View is the default; the
    // Reader door leads to the split view). The model outlives toggles, so the sky keeps its
    // camera and star positions across reader trips; `cameFromSky` makes Back return to the sky
    // after a star click.
    @State private var mode: Mode = .sky
    @StateObject private var skyModel = NightSkyModel()
    @State private var cameFromSky = false

    /// Reader (the split view) or the Night Sky (the full-window galaxy).
    private enum Mode { case reader, sky }

    /// A navigation parked behind the unsaved-edits prompt.
    private enum PendingNav { case open(URL), follow(URL), back, sky }

    var body: some View {
        Group {
            if mode == .sky {
                skyPane.transition(.opacity)
            } else {
                splitView.transition(.opacity)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Theme.bg)
        .background(WindowChrome())   // transparent titlebar from launch (no "grey until resize")
        .task { await loadVault() }
        .alert("You have unsaved edits", isPresented: $showDiscardPrompt) {
            Button("Save") { promptSave() }
            Button("Discard", role: .destructive) { promptDiscard() }
            Button("Cancel", role: .cancel) { pendingNav = nil }
        } message: {
            Text("Save your changes to this note, or discard them?")
        }
        .alert(createIsFolder ? "New folder" : "New note", isPresented: $showCreatePrompt) {
            TextField(createIsFolder ? "Folder name" : "Note name", text: $createName)
                .focused($createFieldFocused)
            Button("Create") { performCreate() }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: showCreatePrompt) { _, shown in
            if shown { claimCreateFieldFocus() }
        }
    }

    /// The reader half: the familiar sidebar + rendered-markdown split.
    private var splitView: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 430)
        } detail: {
            reader
        }
        .navigationSplitViewStyle(.balanced)
        // Window-open focus lands in the search box, not the sidebar's "+" button. defaultFocus
        // declares it; the delayed onAppear claim backs it up (AppKit assigns the initial key
        // view a beat after SwiftUI's appear — same pattern as PromptBar's launch focus).
        .defaultFocus($searchFocused, true)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFocused = true }
        }
    }

    /// The Constellation View takes the whole window (the planetarium moment). The top-left
    /// "Reader" door, Esc, and ⌘⇧G all lead back.
    private var skyPane: some View {
        NightSkyView(vault: vault, vaultLoaded: loaded, model: skyModel,
                     onOpen: { openFromSky($0) },
                     onExit: { requestMode(.reader) })
            .toolbar {
                SkyDoorToolbarItem(icon: "doc.plaintext", label: "Reader View",
                                   help: "Back to the reader (Esc or ⌘⇧G)") { requestMode(.reader) }
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
        cameFromSky = false      // a fresh trail forgets the sky (openFromSky re-sets it)
        select(url)
    }

    // MARK: The Night Sky (mode switching + the star → reader → back-to-sky loop)

    /// Switch reader ⟷ sky. Entering the sky funnels through the same unsaved-edits guard as
    /// every other navigation.
    private func requestMode(_ new: Mode) {
        guard new != mode else { return }
        if new == .sky {
            if editing { if isDirty { pendingNav = .sky; showDiscardPrompt = true; return }; exitEdit() }
            enterSky()
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { mode = .reader }
        }
    }

    private func enterSky() {
        if cameFromSky, let sel = selection { skyModel.highlight(sel) }   // "you were just here"
        withAnimation(.easeInOut(duration: 0.3)) { mode = .sky }
    }

    /// A star was clicked: land in the reader on that note, and let Back lead home to the sky.
    private func openFromSky(_ url: URL) {
        withAnimation(.easeInOut(duration: 0.3)) { mode = .reader }
        open(url)
        cameFromSky = true
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
        backAction()
    }

    /// Back walks the wikilink trail; with the trail exhausted, it returns to the Night Sky if
    /// that's where this reading trip began.
    private func backAction() {
        if canGoBack { goBack() } else if cameFromSky { enterSky() }
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

    /// Commit the buffer to disk and leave edit mode. Cloud sync is DEBOUNCED (markChanged), so Save
    /// is instant locally — no per-note spinner; the sidebar's status line shows the sync. No changes
    /// → just leave. `completion` continues a parked note-switch from the unsaved-edits prompt.
    private func save(then completion: (() -> Void)? = nil) {
        guard editing, let url = selection else { completion?(); return }
        guard editText != savedText else { exitEdit(); completion?(); return }
        do {
            try editText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log("Knowledge editor: save failed — \(ErrorLabel(error))")
            return   // stay in edit mode so the user's text isn't lost
        }
        savedText = editText
        note = KnowledgeVault.read(url)            // refresh the rendered view behind us
        exitEdit()
        VaultActivity.shared.markChanged()         // schedules the debounced mirror sync
        completion?()
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
        case .back:          backAction()
        case .sky:           enterSky()
        }
    }

    // MARK: Managing the vault (create / delete → macOS Trash · all debounce-synced)

    /// Re-scan the vault after a filesystem change. URLs are stable, so `expanded`/`selection` survive
    /// (a now-missing selection is handled by the caller).
    private func reloadVault() { vault = KnowledgeVault.load() }

    /// Move a note OR a folder to the macOS Trash (recoverable). If the open note was the trashed
    /// item — or lived anywhere inside a trashed folder — land back on Overview.
    private func deleteItem(_ url: URL) {
        guard url != vault?.readme else { return }   // never trash the vault index
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            Log("Knowledge: delete failed — \(ErrorLabel(error))")
            return
        }
        let lostSelection = selection == url || (selection?.path.hasPrefix(url.path + "/") ?? false)
        reloadVault()
        if lostSelection {
            if let r = vault?.readme { open(r) }
            else { selection = nil; note = nil; history = []; historyIndex = -1 }
        }
        VaultActivity.shared.markChanged()
    }

    /// Raise the name prompt for a new note/folder inside `parent` (nil = the vault root).
    private func promptCreate(folder: Bool, in parent: URL?) {
        createIsFolder = folder; createParent = parent; createName = ""; showCreatePrompt = true
    }

    /// The create alert opens with its initial key view on the button row, not the TextField —
    /// so typing lands nowhere until the user clicks the field. Claim it a beat after
    /// presentation (same delayed-claim pattern as PromptBar's launch focus): the FocusState
    /// claim for when SwiftUI honors `.focused` inside alert content, and an AppKit
    /// first-responder walk as the backstop — matched by the field's placeholder, so it can
    /// never grab the sidebar's search box or any other field.
    private func claimCreateFieldFocus() {
        let placeholder = createIsFolder ? "Folder name" : "Note name"
        for delay: TimeInterval in [0.1, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard showCreatePrompt else { return }
                createFieldFocused = true
                for window in NSApp.windows where window.isVisible {
                    guard let field = Self.editableField(in: window.contentView,
                                                         placeholder: placeholder) else { continue }
                    if field.currentEditor() == nil { window.makeFirstResponder(field) }
                    return
                }
            }
        }
    }

    /// Depth-first hunt for an editable NSTextField identified by its placeholder.
    private static func editableField(in view: NSView?, placeholder: String) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable, field.placeholderString == placeholder {
            return field
        }
        for sub in view.subviews {
            if let field = editableField(in: sub, placeholder: placeholder) { return field }
        }
        return nil
    }

    private func performCreate() {
        let dir = createParent ?? vault?.root ?? VaultGenerator.vaultRoot
        if createIsFolder { createFolder(named: createName, in: dir) }
        else { createNote(named: createName, in: dir) }
    }

    private func createNote(named raw: String, in dir: URL) {
        let url = Self.uniqueURL(in: dir, name: Self.cleanName(raw, fallback: "Untitled"), ext: "md")
        let title = url.deletingPathExtension().lastPathComponent
        do {
            try "# \(title)\n\n".write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log("Knowledge: create note failed — \(ErrorLabel(error))")
            return
        }
        reloadVault()
        if let v = vault { expanded.formUnion(v.ancestors(of: url)) }   // reveal its folder chain
        open(url)
        beginEdit()                        // drop straight into typing the body
        VaultActivity.shared.markChanged()
    }

    private func createFolder(named raw: String, in dir: URL) {
        let url = Self.uniqueURL(in: dir, name: Self.cleanName(raw, fallback: "New Folder"), ext: nil)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            Log("Knowledge: create folder failed — \(ErrorLabel(error))")
            return
        }
        reloadVault()
        if let v = vault { expanded.formUnion(v.ancestors(of: url)) }   // reveal the parent chain
        expanded.insert(url)                                            // and open the new folder
        VaultActivity.shared.markChanged()
    }

    /// A safe filename from user input: swap path separators, trim, cap length; fall back if empty.
    private static func cleanName(_ raw: String, fallback: String) -> String {
        let s = raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? fallback : String(s.prefix(120))
    }

    /// `dir/name.ext` (or `dir/name` for a folder), suffixing " 2", " 3"… if it already exists — so we
    /// never overwrite.
    private static func uniqueURL(in dir: URL, name: String, ext: String?) -> URL {
        func make(_ n: String) -> URL {
            let base = dir.appendingPathComponent(n, isDirectory: ext == nil)
            return ext.map { base.appendingPathExtension($0) } ?? base
        }
        var candidate = make(name)
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) { candidate = make("\(name) \(i)"); i += 1 }
        return candidate
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
                .contextMenu {   // right-click empty sidebar space → create at the vault ROOT
                    Button { promptCreate(folder: false, in: nil) } label: { Label("New Note", systemImage: "doc.badge.plus") }
                    Button { promptCreate(folder: true, in: nil) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                }
        }
        .background(Theme.panel)   // subtle elevated chrome — distinct from the black reading pane
    }

    /// Left inset that lines the subtitle up under the "Knowledge" wordmark (past the orb + its gap).
    private let wordmarkInset: CGFloat = 23   // OrbMark(15) + HStack spacing(8)

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {   // title + count = one tight block
                HStack(spacing: 8) {
                    OrbMark(size: 15)
                    Text("Knowledge").display(22).foregroundStyle(.white)
                    Spacer()
                    newMenu   // the always-visible "you can create things here" affordance
                }
                .frame(maxWidth: .infinity)
                Text(countText).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.secondary)
                    .padding(.leading, wordmarkInset)   // under "Knowledge", not under the orb
            }
            statusLine.padding(.leading, wordmarkInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
    }

    private var countText: String {
        let n = vault?.titleIndex.count ?? 0
        return "\(n) note\(n == 1 ? "" : "s")"
    }

    /// The quiet "+" in the header — the discoverable face of creation (folders also grow a
    /// hover "+", and right-click remains the power path). Creates at the vault root.
    private var newMenu: some View {
        Menu {
            Button { promptCreate(folder: false, in: nil) } label: { Label("New Note", systemImage: "doc.badge.plus") }
            Button { promptCreate(folder: true, in: nil) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New note or folder")
    }

    /// The line under the count: "Saved locally on this Mac" (mirror off) or the live cloud-MCP sync
    /// state — a calm white status dot (a spinner while pushing; deliberately NEVER colored — an
    /// orange "will sync" read as a warning) then the state with an inline, single-color
    /// "(🔒 Encrypted)". @Observable → re-renders live. (Real zero-access AES-256-GCM: the vault
    /// is sealed on this Mac before upload; the server only ever stores ciphertext.)
    @ViewBuilder
    private var statusLine: some View {
        if mirrorEnabled {
            switch VaultActivity.shared.syncState {
            case .synced:  cloudStatus("Synced to Cloud MCP", color: Theme.secondary, dot: .white, spinner: false)
            case .pending: cloudStatus("Will sync soon", color: Theme.secondary, dot: .white, spinner: false)
            case .syncing: cloudStatus("Syncing to Cloud MCP", color: Theme.secondary, dot: .white, spinner: true)
            }
        } else {
            HStack(spacing: 7) {
                Circle().fill(Theme.faint).frame(width: 6, height: 6)
                Text("Saved locally on this Mac").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
        }
    }

    /// A leading status glyph (a glowing dot, or a spinner while syncing) + "<verb> (🔒 Encrypted)"
    /// as one single-colored line — the lock is inline in the Text so it tints with everything else.
    private func cloudStatus(_ verb: String, color: Color, dot: Color, spinner: Bool) -> some View {
        HStack(spacing: 7) {
            if spinner {
                ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 6, height: 6)
            } else {
                Circle().fill(dot).frame(width: 6, height: 6)
                    .shadow(color: dot.opacity(0.6), radius: 2.5)
            }
            HStack(spacing: 6) {
                Text(verb)
                Rectangle().fill(color.opacity(0.35)).frame(width: 1, height: 11)   // subtle divider
                Text("\(Image(systemName: "lock.fill")) Encrypted")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(color)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.faint)
            TextField("Search notes", text: $search)
                .textFieldStyle(.plain).foregroundStyle(.white).font(.system(size: 13))
                .tint(Theme.knowledgeAccent)
                .focused($searchFocused)
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
                    NodeRow(node: node, depth: 0, expanded: $expanded, selection: selection,
                            onSelect: { requestOpen($0) },
                            onCreate: { promptCreate(folder: $1, in: $0) },
                            onDelete: { deleteItem($0) })
                }
            } else if searchResults.isEmpty {
                Text("No matches").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 12).padding(.top, 14)
            } else {
                ForEach(searchResults) { node in
                    NoteRow(url: node.url, title: node.name, depth: 0, selected: node.url == selection,
                            onDelete: { deleteItem($0) }) {
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
                // The actions live in the window's titlebar (no extra row): the glowing
                // "Constellation View" door leads top-left (mode switches funnel through
                // requestMode, so unsaved edits are never dropped), Back rides in beside it
                // after a wikilink jump (or a star click — then it returns to the sky); Edit +
                // Reveal in Finder sit TOGETHER at the top-right. (One ToolbarItemGroup, not two
                // ToolbarItems — split-view detail toolbars left-align multiple separate
                // .primaryAction items; a single group trails correctly.)
                if vault != nil {
                    SkyDoorToolbarItem(icon: "sparkles", label: "Constellation View",
                                       help: "See your knowledge as a galaxy (⌘⇧G)",
                                       placement: .navigation) { requestMode(.sky) }
                }
                if canGoBack || cameFromSky {
                    ToolbarItem(placement: .navigation) {
                        Button(action: requestBack) { Label("Back", systemImage: "chevron.left") }
                            .help(canGoBack ? "Back" : "Back to the Night Sky")
                    }
                }
                if selection != nil {
                    ToolbarItemGroup(placement: .primaryAction) {
                        editToolbarItem
                        if !editing { deleteToolbarButton }
                        revealToolbarButton
                    }
                }
            }
    }

    /// Move the open note to the macOS Trash (icon-only, between Edit and Reveal — reading mode only).
    /// Hidden for the README/Overview — the vault's index shouldn't be one misclick from gone.
    @ViewBuilder
    private var deleteToolbarButton: some View {
        if let url = selection, url != vault?.readme {
            Button(role: .destructive) { deleteItem(url) } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .help("Move to Trash")
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

    /// The Edit ⟷ Save toggle in the titlebar. Save commits locally; the mirror sync is DEBOUNCED
    /// (see the sidebar's status line), so there's no per-note spinner here.
    @ViewBuilder
    private var editToolbarItem: some View {
        if editing {
            Button { save() } label: { Label("Save", systemImage: "checkmark") }
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
            Text(title).font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.Ink.statusInk)
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
    let url: URL
    let name: String
    let depth: Int
    let isOpen: Bool
    let onCreate: (URL, Bool) -> Void
    let onDelete: (URL) -> Void
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        // The disclosure button and the hover "+" sit SIDE BY SIDE (a Menu nested inside a Button's
        // label wouldn't receive clicks reliably); the row background spans both.
        HStack(spacing: 0) {
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
                .padding(.vertical, 5)
                .padding(.leading, CGFloat(depth) * 14 + 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Hover-reveal "+" → create inside THIS folder (zero clutter until the cursor is here).
            Menu {
                Button { onCreate(url, false) } label: { Label("New Note", systemImage: "doc.badge.plus") }
                Button { onCreate(url, true) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hover ? 1 : 0)
            .padding(.trailing, 6)
            .help("New note or folder in \(name)")
        }
        .background(rowBackground(selected: false, hover: hover))
        .onHover { hover = $0 }
        .contextMenu {   // create INSIDE this folder
            Button { onCreate(url, false) } label: { Label("New Note", systemImage: "doc.badge.plus") }
            Button { onCreate(url, true) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            Divider()
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Reveal in Finder", systemImage: "folder") }
            Divider()
            Button(role: .destructive) { onDelete(url) } label: { Label("Move to Trash", systemImage: "trash") }
        }
    }
}

/// A note (leaf) row: a doc glyph + title, accent when selected.
private struct NoteRow: View {
    let url: URL
    let title: String
    let depth: Int
    let selected: Bool
    let onDelete: (URL) -> Void
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
        .contextMenu {
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Reveal in Finder", systemImage: "folder") }
            Divider()
            Button(role: .destructive) { onDelete(url) } label: { Label("Move to Trash", systemImage: "trash") }
        }
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
    let onCreate: (URL, Bool) -> Void   // (parent folder, isFolder)
    let onDelete: (URL) -> Void

    private var isOpen: Bool { expanded.contains(node.url) }

    var body: some View {
        if node.isFolder {
            VStack(alignment: .leading, spacing: 1) {
                FolderRow(url: node.url, name: node.name, depth: depth, isOpen: isOpen,
                          onCreate: onCreate, onDelete: onDelete) {
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
                                        selection: selection, onSelect: onSelect,
                                        onCreate: onCreate, onDelete: onDelete)
                            }
                        }
                        .transition(.accordion)
                    }
                }
                .clipped()
            }
        } else {
            NoteRow(url: node.url, title: node.name, depth: depth, selected: node.url == selection,
                    onDelete: onDelete) {
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
