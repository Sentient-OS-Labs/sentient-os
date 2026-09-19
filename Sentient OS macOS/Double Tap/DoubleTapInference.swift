//
//  DoubleTapInference.swift
//  Sentient OS macOS
//
//  The one model call behind Double Tap: a screenshot of the user's screen + the ENTIRE knowledge
//  base + the drafting instructions → either the reply to paste or a "not a reply box" verdict.
//  Talks to OpenAI's Responses API directly (streamed, so first-token time is measurable) with the
//  user's OWN API key from the Keychain — a deliberate bypass of the FrontierRun seam for this
//  manual-test harness, because a `codex exec` spawn costs seconds and this feature is judged on
//  feel. Every call is COLD by construction: the screenshot is the first thing in the prompt and it
//  differs on every press, so no provider prefix cache can ever match. Reasoning is off, no service
//  tier (measured 2026-09-19: "fast" bought nothing on luna), `store: false` so OpenAI keeps no copy.
//
//  Key methods: draft(screenshot:vault:) · packVault(_:) · apiKey.
//

import Foundation

enum DoubleTapInference {
    static let model = "gpt-5.6-luna"
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    /// Keychain account for the user's OpenAI API key (same helper + service as the mirror secret).
    static let apiKeyAccount = "doubletap.openai.apiKey"

    /// The whole vault rides along, but never past this many bytes of notes (luna's window is 1M
    /// tokens; a typical vault is ~70 KB). Notes beyond the ceiling are dropped, README first kept.
    static let vaultByteCeiling = 600_000

    /// Idle timeout between streamed bytes. The overall deadline is the caller's (DoubleTap).
    static let idleTimeout: TimeInterval = 20

    static var apiKey: String? {
        let key = Keychain.read(apiKeyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    enum Verdict: Equatable { case reply(String), notAMessage }

    struct Timing {
        var firstToken: TimeInterval?
        var total: TimeInterval = 0
        var inputTokens: Int?
        var cachedTokens: Int?
        var outputTokens: Int?
    }

    struct Outcome {
        let verdict: Verdict
        let timing: Timing
    }

    enum Failure: Error {
        case noKey
        case noVault(String)
        case http(Int, String)
        case api(String)
        case empty
        case cancelled

        /// Short, content-free line for the notch's ✗ caption.
        var label: String {
            switch self {
            case .noKey: return "no OpenAI key (Dev Tools)"
            case .noVault(let path): return "no knowledge base at \(path)"
            case .http(let code, _): return "OpenAI HTTP \(code)"
            case .api(let message): return "OpenAI: \(message.prefix(80))"
            case .empty: return "empty reply"
            case .cancelled: return "stopped"
            }
        }
    }

    // MARK: The call

    /// One streamed call. `screenshot` is JPEG bytes (already downscaled); `vault` is the knowledge
    /// base root. Throws `Failure`; a cancelled Task surfaces as `.cancelled`.
    static func draft(screenshot: Data, vault: URL) async throws -> Outcome {
        guard let key = apiKey else { throw Failure.noKey }
        let packed = packVault(vault)
        guard packed.notes > 0 else { throw Failure.noVault(vault.path) }
        Log("⌘⌘ prompt: \(packed.notes) notes, \(packed.bytes / 1024) KB\(packed.truncated ? " (truncated)" : ""), screenshot \(screenshot.count / 1024) KB")

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "store": false,
            "max_output_tokens": 600,
            "reasoning": ["effort": "none"],
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_image", "detail": "auto",
                     "image_url": "data:image/jpeg;base64," + screenshot.base64EncodedString()],
                    ["type": "input_text", "text": instructions + packed.text],
                ],
            ]],
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = idleTimeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        var timing = Timing()
        var text = ""
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                var detail = ""
                for try await line in bytes.lines where detail.count < 400 { detail += line }
                throw Failure.http(status, detail)
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let data = json.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = event["type"] as? String else { continue }
                switch type {
                case "response.output_text.delta":
                    if timing.firstToken == nil { timing.firstToken = Date().timeIntervalSince(started) }
                    text += event["delta"] as? String ?? ""
                case "response.completed":
                    let usage = (event["response"] as? [String: Any])?["usage"] as? [String: Any]
                    timing.inputTokens = usage?["input_tokens"] as? Int
                    timing.outputTokens = usage?["output_tokens"] as? Int
                    timing.cachedTokens = (usage?["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
                case "response.failed", "error":
                    let error = (event["response"] as? [String: Any])?["error"] as? [String: Any] ?? event
                    throw Failure.api(error["message"] as? String ?? type)
                default:
                    break
                }
            }
        } catch is CancellationError {
            throw Failure.cancelled
        } catch let failure as Failure {
            throw failure
        } catch {
            if Task.isCancelled { throw Failure.cancelled }
            throw Failure.api(ErrorLabel(error))
        }
        timing.total = Date().timeIntervalSince(started)

        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw Failure.empty }
        let verdict: Verdict = reply.uppercased().hasPrefix("NOT_A_MESSAGE") ? .notAMessage : .reply(reply)
        Log("⌘⌘ luna: first text \(ms(timing.firstToken)) · total \(ms(timing.total)) · in \(timing.inputTokens ?? -1) (cached \(timing.cachedTokens ?? 0)) · out \(timing.outputTokens ?? -1) · \(verdict == .notAMessage ? "not a reply box" : "reply")")
        #if DEBUG
        if case .reply(let r) = verdict { Log("⌘⌘ reply:\n\(r)") }   // content — DEBUG only
        #endif
        return Outcome(verdict: verdict, timing: timing)
    }

    private static func ms(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        return "\(Int(seconds * 1000)) ms"
    }

    // MARK: The knowledge base, whole

    struct PackedVault {
        var text = ""
        var notes = 0
        var bytes = 0
        var truncated = false
    }

    /// Every markdown note under `root`, README first, then the rest in path order, each under a
    /// `# relative/path.md` heading. Hidden folders (`.obsidian`, `.git`) are skipped.
    static func packVault(_ root: URL) -> PackedVault {
        var packed = PackedVault()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return packed }
        var paths: [String] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
            paths.append(url.path.replacingOccurrences(of: root.path + "/", with: ""))
        }
        paths.sort { a, b in
            if a == "README.md" { return true }
            if b == "README.md" { return false }
            return a < b
        }
        for rel in paths {
            guard let content = try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) else { continue }
            let chunk = "# \(rel)\n\(content)\n\n"
            if packed.bytes + chunk.utf8.count > vaultByteCeiling { packed.truncated = true; break }
            packed.text += chunk
            packed.bytes += chunk.utf8.count
            packed.notes += 1
        }
        return packed
    }

    // MARK: The instructions

    static let instructions = """
    You are Double Tap, a feature of Sentient OS on this Mac. The user just double-tapped a key while \
    their cursor sat in a text box. The screenshot is their screen at that moment.

    Who the user is: the person the knowledge base below describes. They own this Mac and the \
    account on screen: "me" in an email's recipients, the sending side of a chat. Write as them, \
    never as anyone else in the thread.

    Step 1: decide whether the focused text box is a reply box for an EMAIL or a MESSAGE (chat, DM, \
    SMS, iMessage, WhatsApp, Slack, Discord, LinkedIn, and the like) that the user is replying to. \
    Code editors, terminals, search fields, forms, notes, documents, spreadsheets, address bars, and \
    a blank compose window with no message to answer are NOT.

    If it is NOT, output exactly:
    NOT_A_MESSAGE

    If it IS, write the reply the user would send:
    - Answer the most recent message addressed to the user in the thread the reply box belongs to. \
    Other replies visible on screen are context only; never copy them.
    - Write in the user's own voice, grounded in the knowledge base. Use only facts you can see on \
    screen or find in the knowledge base; never invent commitments, dates, or details.
    - Match the medium: a chat reply is one or two short casual lines; an email reply has a \
    greeting and a sign-off with the user's first name.
    - No em dashes.
    Output ONLY the reply text, nothing else.

    === KNOWLEDGE BASE (everything Sentient knows about the user) ===

    """
}
