//
//  SelfTest_Triage_Pipeline_and_Vault.swift — the original all-in-one headless harness
//  Sentient OS macOS
//
//  A HEADLESS inference dump for development. Launch the built binary with SENTIENT_SELFTEST set
//  and — instead of showing the UI — the app loads the model, runs a few REAL items through the
//  exact same `Triage.prompt → Engine.generate` path the pipeline uses, and writes each item's
//  PROMPT and RAW model OUTPUT (+ the parsed verdict) to a log file, then exits. This is how we
//  see "what did the model actually see, and what did it actually say" with nothing in the way.
//
//  Gated by the env var (and DEBUG-only) so it never fires in normal runs. It reuses the running
//  app's framework/model/FDA, so no separate target is needed.
//
//  Invoke (after building):
//    SENTIENT_SELFTEST=whatsapp "<app>/Contents/MacOS/Sentient OS macOS"
//  Env knobs:
//    SENTIENT_SELFTEST     "whatsapp" | "imessage" | "notes" | "files"  (model dump) ·
//                          "parse" | "chats" | "imchats" | "imdecode" | "notesdecode" | "claudecli" | "vault"  (no model)
//    SENTIENT_SELFTEST_N   item count (default 6)
//    SENTIENT_SELFTEST_OUT output file (default <tmp>/sentient-selftest.txt)
//    SENTIENT_MODEL_PATH   override the dev model path
//

#if DEBUG
import Foundation
import SwiftData

enum SelfTest {
    /// If SENTIENT_SELFTEST is set, run the dump (no UI) and exit. Called first thing in App.init().
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["SENTIENT_SELFTEST"], !mode.isEmpty else { return }
        let n = env["SENTIENT_SELFTEST_N"].flatMap(Int.init) ?? 6
        // ModelLocator already honors SENTIENT_MODEL_PATH; modes that don't load the model
        // (parse/chats/vault) still run when no model is present.
        let modelPath = ModelLocator.resolve() ?? "(model not found — set SENTIENT_MODEL_PATH)"
        let outPath = env["SENTIENT_SELFTEST_OUT"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("sentient-selftest.txt")

        // Do the heavy async work off-main; keep the main runloop alive so the process doesn't fall
        // through to the SwiftUI UI. exit() ends it when the dump is done.
        Task.detached(priority: .userInitiated) {
            await run(mode: mode, count: n, modelPath: modelPath, outPath: outPath)
            exit(0)
        }
        RunLoop.main.run()
    }

    private static func run(mode: String, count: Int, modelPath: String, outPath: String) async {
        FileManager.default.createFile(atPath: outPath, contents: nil)
        let out = FileHandle(forWritingAtPath: outPath)
        defer { try? out?.close() }
        func emit(_ s: String) {
            guard let d = (s + "\n").data(using: .utf8) else { return }
            out?.write(d)
            FileHandle.standardOutput.write(d)
        }

        emit("# Sentient OS self-test — mode=\(mode) count=\(count)")
        emit("# model=\(modelPath)\n")

        // Parser-only mode: deterministic, no model — verify Triage.parse/decide on known strings.
        if mode == "parse" {
            let samples: [(String, String)] = [
                ("ITEM4 stray trailing quote", "{\"summary\":\"User dropping out to build sentient os after a 500k raise.\",\"title\":\"Sentient OS Venture Launch\",\"junk\":false,\"sensitive\":false,\"reminder\":false\"}"),
                ("clean junk", "{\"summary\":\"\",\"title\":\"Chit chat\",\"junk\":true}"),
                ("clean survivor + reminder", "{\"summary\":\"Booked SFO-BOS Aug 3.\",\"title\":\"Flight\",\"junk\":false,\"reminder\":true}"),
                ("trailing comma", "{\"summary\":\"A real keeper here.\",\"title\":\"Keeper\",\"junk\":false,}"),
                ("prose before json", "Sure! Here it is: {\"summary\":\"X happened\",\"title\":\"T\",\"junk\":false}"),
                ("total garbage", "the model rambled and never produced json"),
            ]
            for (label, s) in samples {
                let o = Triage.decide(s)
                emit("• \(label)")
                emit("    in : \(s)")
                emit("    out: verdict=\(o.verdict) reminder=\(o.reminder) title=\(o.title ?? "nil") summary=\"\(o.summary.prefix(60))\"\n")
            }
            return
        }

        // ClaudeCLI mode: no model needed — discovery, ping, and one tiny run through the REAL
        // claude -p spine (binary → env → stdin → JSON envelope). Verifies the compute waterfall's
        // tier-1 path end to end on this Mac.
        if mode == "claudecli" {
            emit("binary: \(ClaudeCLI.locateBinary() ?? "NOT FOUND")")
            let availability = await ClaudeCLI.shared.validate(force: true)
            emit("availability: \(availability)")
            guard case .available = availability else { return }
            do {
                var inv = ClaudeCLI.Invocation(prompt: "Reply with exactly: SPINE_OK")
                inv.model = .sonnet
                inv.timeout = 120
                let envelope = try await ClaudeCLI.shared.run(inv)
                emit("result: \(envelope.result)")
                emit("session: \(envelope.sessionID ?? "nil") · turns: \(envelope.numTurns ?? -1) · \(envelope.durationMS ?? -1)ms · cost: $\(envelope.totalCostUSD ?? 0) · denials: \(envelope.permissionDenialCount)")
                emit(envelope.result.contains("SPINE_OK") ? "✅ spine OK" : "⚠️ unexpected result text")
            } catch { emit("run FAILED: \(error)") }
            return
        }

        // Mirror mode: no model — exercise the REAL MirrorClient against the live (or local,
        // via SENTIENT_MIRROR_BASE) MCP mirror: enable → push the vault → stats → delete. Proves
        // the read/write token split, zip-replace, and auth header end to end on this Mac.
        if mode == "mirror" {
            emit("base: \(MirrorClient.baseURL)")
            let client = MirrorClient()
            do {
                let url = await client.enable()
                emit("share URL: \(url)")
                emit("vault: \(VaultGenerator.vaultRoot.path)")
                try await client.push()
                emit("✅ pushed vault zip")
                let s = try await client.stats()
                emit("stats: notesRead24h=\(s.notesRead24h) toolCalls24h=\(s.toolCalls24h) last=\(s.lastAccess?.description ?? "nil")")
                try await client.deleteRemote()
                emit("✅ deleted remote copy")
                await client.disable()
                emit("✅ disabled (tokens forgotten)")
            } catch { emit("mirror FAILED: \(error)") }
            return
        }

        // Chat-list modes: deterministic, no model — verify listChats() enumeration (and, for
        // iMessage, that names resolved instead of raw +1415… handles). The WhatsApp flavor also
        // prints the session-type distribution + what the community filters removed (counts only).
        if mode == "chats" || mode == "imchats" {
            do {
                let list = mode == "chats" ? try WhatsAppSource().listChats()
                                           : try iMessageSource().listChats()
                emit("active chats in the last \(ChatWindowing.lookbackDays) days: \(list.count)\n")
                for c in list.prefix(count > 6 ? count : 20) {
                    emit("  [\(c.isGroup ? "group" : "DM  ")] \(c.name)  —  \(c.messageCount) msgs · last \(c.lastActive)")
                }
                if mode == "chats" {
                    let (dbURL, tempDir) = try SQLiteDB.walSafeCopy(of: WhatsAppSource().dbPath)
                    defer { try? FileManager.default.removeItem(at: tempDir) }
                    let reader = try SQLiteReader(path: dbURL.path)
                    var dist: [(Int64, Int64)] = []
                    try reader.forEachRow("SELECT ZSESSIONTYPE, COUNT(*) FROM ZWACHATSESSION GROUP BY 1 ORDER BY 1") { r in
                        dist.append((r.int(0), r.int(1)))
                    }
                    var twins: Int64 = 0
                    try reader.forEachRow("""
                        SELECT COUNT(*) FROM ZWACHATSESSION s
                        WHERE s.ZSESSIONTYPE = 1 AND s.ZPARTNERNAME IN
                            (SELECT ZPARTNERNAME FROM ZWACHATSESSION
                             WHERE ZSESSIONTYPE = 4 AND ZPARTNERNAME IS NOT NULL)
                        """) { r in twins = r.int(0) }
                    emit("\nsession types (0=DM 1=group 2=broadcast 3=status 4=community): "
                         + dist.map { "\($0.0)=\($0.1)" }.joined(separator: " · "))
                    emit("community filter removes: \(dist.first { $0.0 == 4 }?.1 ?? 0) homes + \(twins) announcement twins")
                }
            } catch { emit("listChats FAILED: \(error)") }
            return
        }

        // iMessage decode-rate validation: deterministic, no model, STATS ONLY (no message
        // content) — proves the typedstream heuristic on this Mac's real chat.db. Rows carrying
        // BOTH plain text and a blob are ground truth: the decoded blob must equal the text.
        if mode == "imdecode" {
            do {
                let (dbURL, tempDir) = try SQLiteDB.walSafeCopy(of: iMessageSource().dbPath)
                defer { try? FileManager.default.removeItem(at: tempDir) }
                let reader = try SQLiteReader(path: dbURL.path)
                let floorNS = Int64(ChatWindowing.lookbackFloor.timeIntervalSinceReferenceDate * 1e9)
                var ok = 0, fail = 0, match = 0, mismatch = 0, checked = 0, plainOnly = 0, empty = 0
                try reader.forEachRow("""
                    SELECT text, attributedBody FROM message
                    WHERE date >= \(floorNS) AND associated_message_type = 0 AND item_type = 0
                    """) { r in
                    let text = r.text(0)
                    guard let blob = r.blob(1) else {
                        if text?.isEmpty == false { plainOnly += 1 } else { empty += 1 }
                        return
                    }
                    guard let decoded = iMessageSource.typedstreamText(blob) else { fail += 1; return }
                    ok += 1
                    if let text, !text.isEmpty {
                        checked += 1
                        if decoded == text { match += 1 } else { mismatch += 1 }
                    }
                }
                emit("last \(ChatWindowing.lookbackDays) days · blob rows: \(ok) decoded / \(fail) failed (\(String(format: "%.2f", 100.0 * Double(ok) / Double(max(ok + fail, 1))))%)")
                emit("plain-text-only rows: \(plainOnly) · no-body rows skipped: \(empty)")
                emit("ground truth (rows with text AND blob): \(match) match / \(mismatch) mismatch of \(checked)")
                emit(fail == 0 && mismatch == 0 ? "✅ decode clean" : "⚠️ inspect failures before trusting windows")
            } catch { emit("imdecode FAILED: \(error)") }
            return
        }

        // Notes decode-rate validation: deterministic, no model, STATS ONLY (no note content) —
        // proves the gunzip → protobuf 2→3→2 recipe on this Mac's real NoteStore.sqlite.
        if mode == "notesdecode" {
            do {
                let (dbURL, tempDir) = try SQLiteDB.walSafeCopy(of: NotesSource().dbPath)
                defer { try? FileManager.default.removeItem(at: tempDir) }
                let reader = try SQLiteReader(path: dbURL.path)
                var total = 0, locked = 0, deleted = 0, noBlob = 0, ok = 0, fail = 0, empty = 0
                try reader.forEachRow("""
                    SELECT o.ZISPASSWORDPROTECTED, o.ZMARKEDFORDELETION, d.ZDATA
                    FROM ZICCLOUDSYNCINGOBJECT o JOIN ZICNOTEDATA d ON o.ZNOTEDATA = d.Z_PK
                    """) { r in
                    total += 1
                    if r.int(0) == 1 { locked += 1; return }
                    if r.int(1) == 1 { deleted += 1; return }
                    guard let blob = r.blob(2) else { noBlob += 1; return }
                    guard let text = NotesSource.decodeBody(blob) else { fail += 1; return }
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { empty += 1 }
                    else { ok += 1 }
                }
                emit("note rows: \(total) · locked: \(locked) · deleted: \(deleted) · no-blob: \(noBlob)")
                emit("decode: \(ok) ok / \(fail) FAIL / \(empty) empty-text")
                emit(fail == 0 ? "✅ decode clean" : "⚠️ inspect failures before trusting notes")
            } catch { emit("notesdecode FAILED: \(error)") }
            return
        }

        // Vault mode: exercise the REAL Stage-2 path (Store → VaultGenerator → ~/Sentient OS -- The Vault).
        //   SENTIENT_SELFTEST_N>0   → subset (cheap plumbing check);  0/unset → full vault
        //   SENTIENT_VAULT_EFFORT   → effort override (default xhigh; direct route only)
        //   SENTIENT_VAULT_ROUTE    → "direct" forces the API fallback; default auto (agentic when claude works)
        if mode == "vault" {
            let env = ProcessInfo.processInfo.environment
            let want = env["SENTIENT_SELFTEST_N"].flatMap(Int.init) ?? 0
            let effort = env["SENTIENT_VAULT_EFFORT"] ?? "xhigh"
            let route = env["SENTIENT_VAULT_ROUTE"] ?? "auto"
            let container: ModelContainer
            do { container = try ModelContainer(for: LedgerEntry.self, Summary.self, SourceCursor.self) }
            catch { emit("ModelContainer FAILED: \(error)"); return }
            let store = Store(modelContainer: container)
            var summaries = await store.survivorSummaries()
            emit("survivor summaries in store: \(summaries.count)")
            if want > 0 && want < summaries.count { summaries = Array(summaries.prefix(want)) }
            let maxTokens = (want > 0 && want <= 400) ? 32_000 : 128_000
            emit("generating vault from \(summaries.count) summaries · route=\(route) · effort=\(effort) · maxTokens=\(maxTokens)…")
            do {
                let t0 = Date()
                let gen = VaultGenerator()
                let onP: @Sendable (VaultGenerator.Progress) -> Void = { p in
                    switch p {
                    case .receiving(let c): if c % 15_000 < 1_600 { print("  …received \(c) chars") }
                    case .writing(let n):   print("  …\(n) notes written")
                    default: break
                    }
                }
                let res = route == "direct"
                    ? try await gen.generateDirect(summaries: summaries, effort: effort,
                                                   maxTokens: maxTokens, onProgress: onP)
                    : try await gen.generate(summaries: summaries, effort: effort,
                                             maxTokens: maxTokens, onProgress: onP)
                emit("✅ DONE in \(Int(Date().timeIntervalSince(t0)))s — notes=\(res.notes) folders=\(res.folders) input=\(res.inputTokens) output=\(res.outputTokens) stop=\(res.stopReason)")
                emit("vault → \(res.vaultPath)")
                let md = ((try? FileManager.default.subpathsOfDirectory(atPath: res.vaultPath)) ?? [])
                    .filter { $0.hasSuffix(".md") }.sorted()
                emit("\(md.count) .md files:")
                for f in md { emit("  \(f)") }
            } catch { emit("generate FAILED: \(error)") }
            return
        }

        // Optional chat filter for the chat-source dumps: SENTIENT_SELFTEST_CHATS = name
        // substrings joined by "|". Returns the matched chat ids, or nil for "all chats".
        func chatFilter(_ all: [ChatInfo]) -> Set<String>? {
            let want = (ProcessInfo.processInfo.environment["SENTIENT_SELFTEST_CHATS"] ?? "")
                .split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            guard !want.isEmpty else { return nil }
            let matched = all.filter { c in want.contains { c.name.lowercased().contains($0) } }
            emit("chat filter → \(matched.count) matched: \(matched.map(\.name).joined(separator: " · "))\n")
            return Set(matched.map(\.id))
        }

        // 1) Build the source + scan candidates.
        let source: any DataSource
        let maxTokens: Int
        switch mode {
        case "whatsapp":
            source = WhatsAppSource(chatJIDs: chatFilter((try? WhatsAppSource().listChats()) ?? []))
            maxTokens = 16384
        case "imessage":
            source = iMessageSource(chatGUIDs: chatFilter((try? iMessageSource().listChats()) ?? []))
            maxTokens = 16384
        case "notes":
            source = NotesSource(); maxTokens = 4096
        case "files":
            guard let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
                emit("could not locate ~/Downloads"); return
            }
            source = FilesSource(root: dl, label: "Downloads"); maxTokens = 4096
        default:
            emit("unknown mode '\(mode)' (use whatsapp | imessage | notes | files)"); return
        }

        let candidates: [Candidate]
        do { candidates = try source.scan(since: nil) }
        catch { emit("scan FAILED: \(error)"); return }
        emit("scanned \(candidates.count) candidates; dumping first \(min(count, candidates.count))\n")
        guard !candidates.isEmpty else { emit("nothing to dump."); return }

        // 2) Load the model once.
        let engine = Engine(modelPath: modelPath, maxNumTokens: maxTokens)
        do { try await engine.load() }
        catch { emit("engine load FAILED: \(error)"); return }

        // 3) Per item: dump PROMPT + RAW OUTPUT + parsed verdict.
        var empties = 0
        for (i, cand) in candidates.prefix(count).enumerated() {
            let label = cand.metadata["folder"] ?? cand.metadata["displayPath"] ?? cand.id
            do {
                let artifact = try source.load(cand)
                let prompt = Triage.prompt(for: artifact, currentDate: Date())
                let result = try await engine.generate(prompt: prompt, imageData: artifact.imageData)
                let outcome = Triage.decide(result.text)
                let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty { empties += 1 }

                emit("============================================================")
                emit("ITEM \(i + 1)/\(min(count, candidates.count)) — \(label)")
                emit("prompt: \(prompt.count) chars · gen: \(String(format: "%.1f", result.totalTime))s")
                emit("------------------------- PROMPT -------------------------")
                emit(prompt)
                emit("----------------------- RAW OUTPUT -----------------------")
                emit(raw.isEmpty ? "⚠️ (EMPTY — model returned no text)" : result.text)
                emit("------------------------- PARSED -------------------------")
                emit("verdict=\(outcome.verdict)  reminder=\(outcome.reminder)  title=\(outcome.title ?? "nil")")
                emit("")
            } catch {
                emit("ITEM \(i + 1) — \(label) FAILED: \(error)\n")
            }
        }

        await engine.unload()
        emit("# done. empty responses: \(empties)/\(min(count, candidates.count)). full dump → \(outPath)")
    }
}
#endif
