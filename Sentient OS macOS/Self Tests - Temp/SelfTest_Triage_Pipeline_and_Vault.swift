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
//                          "tokens"  (WhatsApp window token-cost measurement, model) ·
//                          "parse" | "chats" | "imchats" | "imdecode" | "notesdecode" | "codexcli"
//                          | "skipping" | "skipcensus" | "cookiedecrypt"  (proactive PART-3 cookies)
//                          | "fileiter" | "chatiter" | "notesiter"  (iterative-core proofs, no model)
//    SENTIENT_SELFTEST_DOMAINS  cookiedecrypt scope (comma-separated regs, e.g. amazon.com,github.com; empty = all)
//    SENTIENT_SELFTEST_N   item count (default 6)
//    SENTIENT_SELFTEST_OUT output file (default <tmp>/sentient-selftest.txt)
//    SENTIENT_MODEL_PATH   override the dev model path
//

#if DEBUG
import Foundation

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
                emit("    out: verdict=\(o.verdict) title=\(o.title ?? "nil") summary=\"\(o.summary.prefix(60))\"\n")
            }
            return
        }

        // File-skipping modes: deterministic, no model — fixture assertions ("skipping") and a
        // read-only census of the real standard folders ("skipcensus"). See SelfTest_FileSkipping.swift.
        if mode == "skipping" { SelfTestFileSkipping.synthetic(emit: emit); return }
        if mode == "skipcensus" { SelfTestFileSkipping.census(emit: emit); return }

        // Iterative core proof: deterministic, no model/codex — ItemKey tiebreak · the
        // newer-than-mark partition (twin at the boundary) · CycleStore round-trip · FilesConnector.
        if mode == "fileiter" { await SelfTestFileIter.run(emit: emit); return }

        // NotesConnector against the live Notes DB — structural invariants (needs Full Disk Access).
        if mode == "notesiter" { await SelfTestNotesIter.run(emit: emit); return }

        // WhatsApp + iMessage connectors against the live DBs — structural invariants (needs FDA).
        if mode == "chatiter" { await SelfTestChatIter.run(emit: emit); return }

        // CodexCLI mode: no model needed — discovery, ping, and one tiny run through the REAL
        // codex exec spine (binary → env → stdin → JSONL envelope). Verifies the compute
        // waterfall's tier-1 path end to end on this Mac.
        if mode == "codexcli" {
            emit("binary: \(CodexCLI.locateBinary() ?? "NOT FOUND")")
            let availability = await CodexCLI.shared.validate(force: true)
            emit("availability: \(availability)")
            guard case .available = availability else { return }
            do {
                var inv = CodexCLI.Invocation(prompt: "Reply with exactly: SPINE_OK")
                inv.effort = .low            // a ping doesn't need the xhigh default
                inv.timeout = 120
                let envelope = try await CodexCLI.shared.run(inv)
                emit("result: \(envelope.result)")
                emit("session: \(envelope.sessionID ?? "nil") · items: \(envelope.numTurns ?? -1) · \(envelope.durationMS ?? -1)ms · tokens in/cached/out: \(envelope.inputTokens ?? -1)/\(envelope.cachedInputTokens ?? -1)/\(envelope.outputTokens ?? -1)")
                emit(envelope.result.contains("SPINE_OK") ? "✅ spine OK" : "⚠️ unexpected result text")
            } catch { emit("run FAILED: \(error)") }
            return
        }

        // Cookie-decrypt mode: no model — the proactive PART-3 trusted layer. Locate Chrome's cookie
        // DB, read the Keychain "Chrome Safe Storage" key (may prompt once), decrypt v10 cookies, and
        // write a Playwright storageState. Scope with SENTIENT_SELFTEST_DOMAINS (empty = all).
        if mode == "cookiedecrypt" {
            let domains = (ProcessInfo.processInfo.environment["SENTIENT_SELFTEST_DOMAINS"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            emit("chrome cookie DB: \(CookieDecryptor.cookieDBPath() ?? "NOT FOUND")")
            emit("domains: \(domains.isEmpty ? "(all)" : domains.joined(separator: ", "))")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-ss-selftest.json")
            do {
                let r = try CookieDecryptor.makeStorageState(domains: domains, to: url)
                emit("decrypted: \(r.decrypted) · written to storageState: \(r.written)")
                emit("storageState: \(url.path)")
                if let data = try? Data(contentsOf: url),
                   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let cookies = obj["cookies"] as? [[String: Any]] {
                    let sample = cookies.prefix(8).map { "\(($0["domain"] as? String) ?? "?")  \(($0["name"] as? String) ?? "?")" }
                    emit("sample (domain · name, no values):\n  " + sample.joined(separator: "\n  "))
                    emit(r.written > 0 ? "✅ cookies decrypted" : "⚠️ zero cookies written (logged out, or wrong domain scope?)")
                }
            } catch { emit("FAILED: \((error as? LocalizedError)?.errorDescription ?? "\(error)")") }
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

        // Token-budget calibration (mode "tokens"): REAL WhatsApp windows through the REAL chat
        // prompts on the REAL engine, with LiteRT-LM's benchmark instrumentation reporting the
        // EXACT prefill token count per window. Answers "how many tokens does a full window
        // actually cost?" — the datum behind ChatWindowing.maxWindowBytes. Two synthetic
        // empty-window runs first isolate the fixed prompt-template overhead per flavour, so we
        // can report a pure conversation-bytes → conversation-tokens ratio. STATS ONLY in the
        // log — chat names + sizes, never message content.
        if mode == "tokens" {
            let source = WhatsAppSource(chatJIDs: chatFilter((try? WhatsAppSource().listChats()) ?? []))
            let candidates: [Candidate]
            do { candidates = try source.eligibleWindows().flatMap { $0.items.map(\.item) } }
            catch { emit("eligibleWindows FAILED: \(error)"); return }
            emit("windows in backlog: \(candidates.count) · current byte budget: \(ChatWindowing.maxWindowBytes)\n")
            guard !candidates.isEmpty else { return }

            let engine = Engine(modelPath: modelPath, maxNumTokens: ChatWindowing.kvCacheTokens, collectStats: true)
            do { try await engine.load() }
            catch { emit("engine load FAILED: \(error)"); return }

            // Fixed template overhead per prompt flavour (instructions + chat scaffolding, zero
            // conversation bytes). Window tokens = prefill − overhead[flavour].
            var overhead: [String: Int] = [:]
            for flavour in ["0", "1"] {
                let cand = Candidate(id: "calibration", kind: .whatsapp,
                                     cursorKey: "", cursorValue: "", itemDate: Date(),
                                     metadata: ["isGroup": flavour, "windowText": ""])
                let prompt = Triage.prompt(for: Artifact(candidate: cand, text: ""), currentDate: Date())
                do {
                    let r = try await engine.generate(prompt: prompt)
                    overhead[flavour] = r.prefillTokens
                    emit("template overhead \(flavour == "1" ? "(group)" : "(DM)   "): \(r.prefillTokens.map(String.init) ?? "??") tokens · \(prompt.utf8.count) prompt bytes")
                } catch { emit("calibration \(flavour) FAILED: \(error)") }
            }
            emit("")

            // Even-stride sample across the whole backlog → a mix of chats, ages, and languages.
            // (count == 6 is the harness default — treat it as "unset" and take a bigger sample.)
            let n = min(count == 6 ? 24 : count, candidates.count)
            let step = max(1, candidates.count / n)
            let sample = (0..<n).map { candidates[min($0 * step, candidates.count - 1)] }

            struct Row { let winBytes, winTokens, prefill, decode: Int
                         let ratio, pTPS, dTPS, secs: Double }
            var rows: [Row] = []
            func pad(_ s: String, _ w: Int) -> String {
                s.count >= w ? s : s.padding(toLength: w, withPad: " ", startingAt: 0)
            }
            emit(pad("chat", 26) + " msgs   bytes  prefill  win-tok  B/tok  decode")
            for (i, cand) in sample.enumerated() {
                do {
                    let artifact = Artifact(candidate: cand, text: cand.metadata["windowText"] ?? "")
                    let prompt = Triage.prompt(for: artifact, currentDate: Date())
                    let r = try await engine.generate(prompt: prompt)
                    guard let prefill = r.prefillTokens, prefill > 0 else {
                        emit("ITEM \(i + 1): no benchmark info — skipped"); continue
                    }
                    let winBytes = (cand.metadata["windowText"] ?? "").utf8.count
                    let winTokens = max(1, prefill - (overhead[cand.metadata["isGroup"] ?? "0"] ?? 0))
                    let row = Row(winBytes: winBytes, winTokens: winTokens, prefill: prefill,
                                  decode: r.decodeTokens ?? 0,
                                  ratio: Double(winBytes) / Double(winTokens),
                                  pTPS: r.prefillTokensPerSecond ?? 0,
                                  dTPS: r.decodeTokensPerSecond ?? 0, secs: r.totalTime)
                    rows.append(row)
                    let name = String((cand.metadata["name"] ?? "?").prefix(21))
                        + (cand.metadata["isGroup"] == "1" ? " [g]" : "")
                    emit(pad(name, 26)
                         + String(format: " %4d %7d %8d %8d %6.2f %7d",
                                  Int(cand.metadata["msgCount"] ?? "") ?? 0, winBytes, prefill, winTokens, row.ratio, row.decode))
                } catch { emit("ITEM \(i + 1) FAILED: \(error)") }
            }
            await engine.unload()
            guard !rows.isEmpty else { emit("no measurements."); return }

            func med(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
            let ratios = rows.map(\.ratio)
            let minR = ratios.min()!, medR = med(ratios), maxR = ratios.max()!
            let meanFill = rows.map { Double($0.prefill) }.reduce(0, +) / Double(rows.count)
            let meanDecode = rows.map { Double($0.decode) }.reduce(0, +) / Double(rows.count)
            let meanSecs = rows.map(\.secs).reduce(0, +) / Double(rows.count)
            emit("""

            ===== AGGREGATE (\(rows.count) windows) =====
            conversation bytes/token   min \(String(format: "%.2f", minR)) · median \(String(format: "%.2f", medR)) · max \(String(format: "%.2f", maxR))
            mean prefill               \(Int(meanFill)) tokens (\(String(format: "%.1f", 100 * meanFill / 16_384))% of the 16,384 context)
            mean decode                \(Int(meanDecode)) tokens · mean wall-clock \(String(format: "%.1f", meanSecs))s/window
            mean prefill / decode toks-per-sec   \(Int(rows.map(\.pTPS).reduce(0, +) / Double(rows.count))) · \(Int(rows.map(\.dTPS).reduce(0, +) / Double(rows.count)))

            ===== WHAT-IF byte budgets (worst-case = min ratio, expected = median) =====
            """)
            let groupOverhead = Double(overhead["1"] ?? 0)
            for budget in [5_000, 10_000, 15_000, 20_000, 25_000, 30_000] {
                let worst = Double(budget) / minR + groupOverhead
                let typical = Double(budget) / medR + groupOverhead
                emit(String(format: "  %6d bytes → prefill ~%5.0f typical · ~%5.0f worst-case  (%4.1f%% / %4.1f%% of 16,384)",
                            budget, typical, worst, 100 * typical / 16_384, 100 * worst / 16_384))
            }
            emit("\n# done → \(outPath)")
            return
        }

        // 1) List candidates via the iterative path (each source's eligible…()) + a per-source loader.
        let candidates: [Candidate]
        let load: (Candidate) throws -> Artifact
        let maxTokens: Int
        do {
            switch mode {
            case "whatsapp":
                candidates = try WhatsAppSource(chatJIDs: chatFilter((try? WhatsAppSource().listChats()) ?? []))
                    .eligibleWindows().flatMap { $0.items.map(\.item) }
                load = { Artifact(candidate: $0, text: $0.metadata["windowText"] ?? "") }
                maxTokens = ChatWindowing.kvCacheTokens
            case "imessage":
                candidates = try iMessageSource(chatGUIDs: chatFilter((try? iMessageSource().listChats()) ?? []))
                    .eligibleWindows().flatMap { $0.items.map(\.item) }
                load = { Artifact(candidate: $0, text: $0.metadata["windowText"] ?? "") }
                maxTokens = ChatWindowing.kvCacheTokens
            case "notes":
                candidates = try NotesSource().eligibleNotes()
                load = { Artifact(candidate: $0, text: $0.metadata["noteText"] ?? "") }
                maxTokens = 4096
            case "files":
                guard let files = FileRoot.downloads.source else { emit("could not locate ~/Downloads"); return }
                candidates = files.eligibleFiles()
                load = { try FilesSource.loadArtifact($0) }
                maxTokens = 4096
            default:
                emit("unknown mode '\(mode)' (use whatsapp | imessage | notes | files)"); return
            }
        } catch { emit("listing FAILED: \(error)"); return }
        emit("listed \(candidates.count) candidates; dumping first \(min(count, candidates.count))\n")
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
                let artifact = try load(cand)
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
                emit("verdict=\(outcome.verdict)  title=\(outcome.title ?? "nil")")
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
