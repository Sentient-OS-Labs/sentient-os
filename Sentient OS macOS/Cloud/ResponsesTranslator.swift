//
//  ResponsesTranslator.swift
//  Sentient OS macOS
//
//  The local-endpoint translator: a loopback-only HTTP proxy that sits between codex and a
//  naive OpenAI-Responses server (LM Studio, Ollama, vLLM…), translating codex's
//  OpenAI-proprietary wire dialect into plain Responses API both ways — so computer use (and
//  every MCP tool) works on endpoints that silently drop codex's `{"type":"namespace"}` tool
//  bundles and reject its array-valued tool outputs (both measured on LM Studio, 2026-07-24).
//
//  What it rewrites (all shapes live-verified against LM Studio):
//   REQUESTS  → namespace tool bundles flattened to `ns__tool` functions · history
//               `function_call.namespace` merged into the flattened name · array
//               `function_call_output`s become a string + the screenshots relocated into a
//               following user message · `reasoning` replay items and `include` dropped ·
//               server-side-only tool types (web_search…) dropped.
//   RESPONSES → streamed `function_call` items un-flattened back into the
//               `{name, namespace}` shape codex routes on (SSE-aware, frame-preserving).
//
//  Key surface: ensureRunning(upstream:) → the port codex should dial · Rewrite (the pure,
//  testable JSON transforms). Used by CustomProvider.providerOverrides() when
//  `needsTranslator` (every custom preset except OpenRouter, whose server speaks the dialect
//  natively). Loopback only; forwards Authorization untouched; one connection per codex
//  request (Connection: close).
//

import Foundation
import Network

final class ResponsesTranslator: @unchecked Sendable {

    static let shared = ResponsesTranslator()

    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var upstreamBase: String = ""

    /// Long-generation-friendly upstream session (a local 35B can think for minutes).
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3_600
        cfg.timeoutIntervalForResource = 7_200
        return URLSession(configuration: cfg)
    }()

    // MARK: - Lifecycle

    /// Start (or reuse) the proxy for `upstream` (the user's REAL base URL, `/v1` included)
    /// and return the loopback port codex should dial. Idempotent; an upstream change
    /// restarts the listener. Returns nil if the listener can't bind (caller falls back to
    /// dialing the endpoint directly — worse but honest).
    func ensureRunning(upstream: String) -> UInt16? {
        // `localhost` resolves to ::1 first and local servers usually bind IPv4-only — every
        // request then burns a refused IPv6 attempt (log noise + latency). Normalize.
        let upstream = upstream
            .replacingOccurrences(of: "://localhost", with: "://127.0.0.1")
        lock.lock(); defer { lock.unlock() }
        if let boundPort, listener != nil, upstreamBase == upstream { return boundPort }
        listener?.cancel(); listener = nil; boundPort = nil
        upstreamBase = upstream

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else {
            Log("ResponsesTranslator: listener failed to bind")
            return nil
        }
        l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed(let err) = state { Log("ResponsesTranslator: listener failed: \(err)"); ready.signal() }
        }
        l.start(queue: DispatchQueue(label: "sentient.translator.listener"))
        _ = ready.wait(timeout: .now() + 3)
        guard case .ready = l.state, let port = l.port?.rawValue else {
            l.cancel()
            Log("ResponsesTranslator: listener never became ready")
            return nil
        }
        listener = l
        boundPort = port
        Log("ResponsesTranslator: up on 127.0.0.1:\(port) → \(upstream)")
        return port
    }

    // MARK: - Per-connection service

    private func serve(_ conn: NWConnection) {
        conn.start(queue: DispatchQueue(label: "sentient.translator.conn"))
        Task.detached { [weak self] in
            guard let self else { return }
            do { try await self.handle(conn) }
            catch { Log("ResponsesTranslator: connection error: \(error)") }
            conn.cancel()
        }
    }

    private func handle(_ conn: NWConnection) async throws {
        let (head, body) = try await Self.readRequest(conn)
        let upstream = lock.withSentientLock { upstreamBase }

        // Route: strip the `/v1` prefix codex dials (our advertised base is …:port/v1) and
        // append the remainder to the real upstream base (which carries its own /v1).
        var path = head.path
        if path.hasPrefix("/v1") { path = String(path.dropFirst(3)) }
        guard let url = URL(string: upstream + path) else {
            try await Self.write(conn, Self.plainResponse(status: 502, body: "translator: bad upstream URL"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = head.method
        for (k, v) in head.headers
        where !["host", "content-length", "connection", "accept-encoding", "transfer-encoding"].contains(k) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        var mapping: [String: (ns: String, name: String)] = [:]
        if head.method == "POST", path.hasSuffix("/responses"), let body {
            let (rewritten, map) = Rewrite.request(body)
            mapping = map
            request.httpBody = rewritten
        } else {
            request.httpBody = body
        }

        let (bytes, response) = try await session.bytes(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 502
        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""

        guard contentType.contains("text/event-stream") else {
            // Non-SSE (errors, /models, stream:false) — buffer and relay verbatim.
            var buf = Data()
            for try await byte in bytes { buf.append(byte) }
            try await Self.write(conn, Self.plainResponse(status: status, contentType: contentType, bodyData: buf))
            return
        }

        // SSE relay: line-preserving (blank lines are frame delimiters — never drop them),
        // rewriting only the `data:` payloads that carry function_call items.
        try await Self.write(conn, Data(("HTTP/1.1 \(status) OK\r\n"
            + "Content-Type: text/event-stream\r\nCache-Control: no-cache\r\n"
            + "Connection: close\r\n\r\n").utf8))
        var lineBuf = Data()
        for try await byte in bytes {
            if byte == 0x0A {
                let line = String(decoding: lineBuf, as: UTF8.self)
                lineBuf.removeAll(keepingCapacity: true)
                let outLine: String
                if line.hasPrefix("data:") {
                    let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    outLine = "data: " + Rewrite.eventData(payload, mapping: mapping)
                } else {
                    outLine = line
                }
                try await Self.write(conn, Data((outLine + "\n").utf8))
            } else if byte != 0x0D {   // normalize CRLF → LF; re-add none (SSE is LF-fine)
                lineBuf.append(byte)
            }
        }
        if !lineBuf.isEmpty {
            try await Self.write(conn, lineBuf)
        }
    }

    // MARK: - The pure transforms (testable without a socket)

    enum Rewrite {

        /// Rewrite one codex `/responses` request body for a naive endpoint. Returns the new
        /// body + the flattened-name registry the response side un-flattens with.
        static func request(_ body: Data) -> (Data, [String: (ns: String, name: String)]) {
            guard var root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return (body, [:])
            }
            var mapping: [String: (ns: String, name: String)] = [:]

            // 1. Tools: flatten namespace bundles; drop server-side-only types.
            if let tools = root["tools"] as? [[String: Any]] {
                var out: [[String: Any]] = []
                for tool in tools {
                    switch tool["type"] as? String {
                    case "namespace":
                        let ns = tool["name"] as? String ?? "tools"
                        let nsDesc = (tool["description"] as? String) ?? ""
                        for inner in (tool["tools"] as? [[String: Any]] ?? []) {
                            guard let name = inner["name"] as? String else { continue }
                            let flat = "\(ns)__\(name)"
                            mapping[flat] = (ns, name)
                            var fn: [String: Any] = ["type": "function", "name": flat, "strict": false]
                            let desc = [nsDesc, (inner["description"] as? String) ?? ""]
                                .filter { !$0.isEmpty }.joined(separator: ". ")
                            if !desc.isEmpty { fn["description"] = desc }
                            fn["parameters"] = inner["parameters"]
                                ?? ["type": "object", "properties": [String: Any]()]
                            out.append(fn)
                        }
                    case "function", "custom":
                        out.append(tool)
                    default:
                        break   // web_search etc. — OpenAI-server-side, meaningless here
                    }
                }
                root["tools"] = out
            }

            // 2. `include` is OpenAI-only (reasoning.encrypted_content).
            root.removeValue(forKey: "include")

            // 3. History: merge namespaces into names, relocate screenshots, drop reasoning.
            if let input = root["input"] as? [[String: Any]] {
                var out: [[String: Any]] = []
                for var item in input {
                    switch item["type"] as? String {
                    case "reasoning":
                        continue   // OpenAI replay internals; naive endpoints choke
                    // (screenshot pruning happens in a second pass below — see pruneStaleImages)
                    case "function_call", "custom_tool_call":
                        if let ns = item["namespace"] as? String,
                           let name = item["name"] as? String {
                            let flat = "\(ns)__\(name)"
                            mapping[flat] = (ns, name)
                            item["name"] = flat
                            item.removeValue(forKey: "namespace")
                        }
                        out.append(item)
                    case "function_call_output", "custom_tool_call_output":
                        let (rewritten, imageMessage) = splitOutput(item)
                        out.append(rewritten)
                        if let imageMessage { out.append(imageMessage) }
                    default:
                        out.append(item)
                    }
                }
                root["input"] = pruneStaleImages(out)
            }

            guard let data = try? JSONSerialization.data(withJSONObject: root) else { return (body, mapping) }
            return (data, mapping)
        }

        /// Keep only the NEWEST image in the replayed history (including Sidekick's initial
        /// display capture in message one); every older image becomes a one-line text note.
        /// Local engines skip prompt caching entirely once vision content is in the prompt, so
        /// a screenshot-per-turn agent loop re-prefills its whole ever-growing history every
        /// call (measured: 10–30s per turn on a 35B by turn 15). Old screenshots are thousands
        /// of tokens the model never needs — it acts on the LATEST view by rule — so pruning
        /// them collapses the prompt back to near-text size each turn.
        private static func pruneStaleImages(_ input: [[String: Any]]) -> [[String: Any]] {
            // Find the last item that carries an image part.
            var lastImageIndex: Int?
            for (i, item) in input.enumerated() where hasImagePart(item) { lastImageIndex = i }
            guard let lastImageIndex else { return input }
            var out = input
            for i in out.indices where i < lastImageIndex && hasImagePart(out[i]) {
                guard var content = out[i]["content"] as? [[String: Any]] else { continue }
                content = content.compactMap { part in
                    guard part["type"] as? String == "input_image" else { return part }
                    return ["type": "input_text",
                            "text": "(an older screenshot was here; omitted — only the newest screenshot is kept)"]
                }
                out[i]["content"] = content
            }
            return out
        }

        private static func hasImagePart(_ item: [String: Any]) -> Bool {
            guard let content = item["content"] as? [[String: Any]] else { return false }
            return content.contains { $0["type"] as? String == "input_image" }
        }

        /// Array-valued tool output → a plain string, with any images relocated into a user
        /// message that follows (the shape LM Studio accepts — live-verified: a vision model
        /// read a relocated screenshot fine, 2026-07-24).
        private static func splitOutput(_ item: [String: Any]) -> ([String: Any], [String: Any]?) {
            guard let parts = item["output"] as? [[String: Any]] else { return (item, nil) }
            var item = item
            var texts: [String] = []
            var images: [[String: Any]] = []
            for part in parts {
                switch part["type"] as? String {
                case "input_text", "output_text", "text":
                    if let t = part["text"] as? String, !t.isEmpty { texts.append(t) }
                case "input_image":
                    images.append(part)
                default:
                    break
                }
            }
            if !images.isEmpty {
                texts.append("(the tool also returned \(images.count == 1 ? "a screenshot" : "\(images.count) screenshots"), attached in the next message)")
            }
            item["output"] = texts.joined(separator: "\n")
            guard !images.isEmpty else { return (item, nil) }
            var content: [[String: Any]] = [["type": "input_text",
                                             "text": "(screenshot returned by the tool call above:)"]]
            content += images
            return (item, ["role": "user", "content": content])
        }

        /// Rewrite one SSE `data:` payload: un-flatten function_call names back into the
        /// `{name, namespace}` shape codex routes on. Non-JSON payloads pass through.
        static func eventData(_ payload: String, mapping: [String: (ns: String, name: String)]) -> String {
            guard !mapping.isEmpty,
                  let data = payload.data(using: .utf8),
                  var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = obj["type"] as? String else { return payload }

            func unflatten(_ item: inout [String: Any]) {
                guard let itemType = item["type"] as? String,
                      itemType == "function_call" || itemType == "custom_tool_call",
                      let flat = item["name"] as? String,
                      let m = mapping[flat] else { return }
                item["name"] = m.name
                item["namespace"] = m.ns
            }

            var changed = false
            if type == "response.output_item.added" || type == "response.output_item.done",
               var item = obj["item"] as? [String: Any] {
                let before = item["name"] as? String
                unflatten(&item)
                if before != item["name"] as? String { obj["item"] = item; changed = true }
            }
            if type == "response.completed" || type == "response.incomplete" || type == "response.failed",
               var resp = obj["response"] as? [String: Any],
               var output = resp["output"] as? [[String: Any]] {
                for i in output.indices {
                    let before = output[i]["name"] as? String
                    unflatten(&output[i])
                    if before != output[i]["name"] as? String { changed = true }
                }
                if changed { resp["output"] = output; obj["response"] = resp }
            }
            guard changed,
                  let out = try? JSONSerialization.data(withJSONObject: obj) else { return payload }
            return String(decoding: out, as: UTF8.self)
        }
    }

    // MARK: - Minimal HTTP plumbing

    private struct RequestHead {
        let method: String
        let path: String
        let headers: [String: String]   // lowercased keys
    }

    /// Read one HTTP/1.1 request (head + Content-Length body) off the connection.
    private static func readRequest(_ conn: NWConnection) async throws -> (RequestHead, Data?) {
        var buf = Data()
        let headEnd = Data("\r\n\r\n".utf8)
        while buf.range(of: headEnd) == nil {
            guard let chunk = try await receive(conn), !chunk.isEmpty else { break }
            buf.append(chunk)
            if buf.count > 4_000_000 { throw URLError(.dataLengthExceedsMaximum) }
        }
        guard let split = buf.range(of: headEnd) else { throw URLError(.badServerResponse) }
        let headData = buf[..<split.lowerBound]
        var body = Data(buf[split.upperBound...])

        let lines = String(decoding: headData, as: UTF8.self).split(separator: "\r\n").map(String.init)
        guard let requestLine = lines.first else { throw URLError(.badServerResponse) }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let head = RequestHead(method: String(parts[0]), path: String(parts[1]), headers: headers)

        let expected = Int(headers["content-length"] ?? "0") ?? 0
        while body.count < expected {
            guard let chunk = try await receive(conn), !chunk.isEmpty else { break }
            body.append(chunk)
        }
        return (head, body.isEmpty ? nil : body)
    }

    private static func receive(_ conn: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                if let error { cont.resume(throwing: error) }
                else if let data { cont.resume(returning: data) }
                else if complete { cont.resume(returning: nil) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    private static func write(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private static func plainResponse(status: Int, contentType: String = "text/plain",
                                      body: String? = nil, bodyData: Data? = nil) -> Data {
        let payload = bodyData ?? Data((body ?? "").utf8)
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: \(contentType.isEmpty ? "application/octet-stream" : contentType)\r\n"
        head += "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + payload
    }
}

private extension NSLock {
    /// Tiny scoped-lock helper (named to avoid colliding with any future stdlib `withLock`).
    func withSentientLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
