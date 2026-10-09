// Bounded searches and actual message/thread reads from selected local Mail accounts.
// The actor owns snapshots, opaque references and issued evidence. No mailbox mutations or model calls.
// Doc: Sources/Documentation - Sources - Local (Files, WhatsApp, iMessage, Notes).md

import Foundation

actor AppleMailResearch {
    nonisolated enum Failure: String, Error { case accessChanged, unavailable, invalidArguments, budgetExceeded, unknownReference }
    nonisolated struct Locator: Codable, Sendable, Equatable {
        let account: String
        let generation: String
        let rowID: Int64
        let messageIDHash: String
    }
    nonisolated struct Seed: Sendable {
        let reference: String
        let locator: Locator
    }
    nonisolated struct MessageEvidence: Codable, Sendable, Equatable {
        let locator: Locator
        let fingerprint: String
        let complete: Bool
    }
    nonisolated struct Evidence: Codable, Sendable {
        let id: String
        let scope: AppleMailResearchAccess.Scope
        let readAt: Date
        let messages: [MessageEvidence]
        let threadSeed: Locator?
        let threadRevision: String?
        let localCoverageComplete: Bool
    }
    private struct Header {
        let row: AppleMailRow
        let fields: [String: String]
        let ids: Set<String>
        let complete: Bool
    }
    private struct Thread {
        let rows: [AppleMailRow]
        let revision: String
        let complete: Bool
    }

    let scope: AppleMailResearchAccess.Scope
    private let root: URL
    private let permitted: @Sendable () -> Bool
    private let salt = UUID().uuidString
    private let deadline: Date
    private var snapshot: AppleMailSnapshot?
    private var snapshotAt = Date.distantPast
    private var headers: [String: Header] = [:]
    private var references: [String: Locator] = [:]
    private var issued: [String: Evidence] = [:]
    private var calls = 0
    private var headerReads = 0
    private var outputBytes = 0
    nonisolated static let scanLimit = 1_500
    nonisolated static let byteLimit = 256 * 1_024

    init(scope: AppleMailResearchAccess.Scope, root: URL, seeds: [Seed] = [], timeout: TimeInterval = 1_800,
         permitted: @escaping @Sendable () -> Bool) {
        self.scope = scope; self.root = root; self.permitted = permitted
        deadline = Date().addingTimeInterval(timeout)
        for seed in seeds where scope.accounts.contains(seed.locator.account) { references[seed.reference] = seed.locator }
    }

    private func check() throws {
        try Task.checkCancellation()
        guard permitted() else { throw Failure.accessChanged }
        guard Date() < deadline else { throw Failure.budgetExceeded }
    }

    private func current(refresh: Bool = false) throws -> AppleMailSnapshot {
        try check()
        if snapshot == nil || refresh || Date().timeIntervalSince(snapshotAt) > 60 {
            snapshot = try AppleMailSnapshot(root: root, selected: scope.accounts, includeAccountLabels: false)
            snapshotAt = Date(); headers.removeAll()
        }
        return snapshot!
    }

    private func locator(_ row: AppleMailRow, _ snapshot: AppleMailSnapshot) -> Locator {
        Locator(account: row.account, generation: snapshot.generation, rowID: row.id,
                messageIDHash: AppleMailSource.digest(row.messageID))
    }
    private func reference(_ row: AppleMailRow, _ snapshot: AppleMailSnapshot) -> String {
        let id = "mail:" + AppleMailSource.digest(salt + row.account + snapshot.generation + String(row.id))
        references[id] = locator(row, snapshot)
        return id
    }
    private func resolve(_ locator: Locator, in snapshot: AppleMailSnapshot) throws -> AppleMailRow {
        guard scope.accounts.contains(locator.account), locator.generation == snapshot.generation,
              let row = snapshot.rows.first(where: { $0.account == locator.account && $0.id == locator.rowID }),
              !row.excluded, AppleMailSource.digest(row.messageID) == locator.messageIDHash else { throw Failure.unavailable }
        return row
    }
    private func resolve(_ reference: String, in snapshot: AppleMailSnapshot) throws -> AppleMailRow {
        guard let locator = references[reference] else { throw Failure.unknownReference }
        return try resolve(locator, in: snapshot)
    }
    private func header(_ row: AppleMailRow, _ snapshot: AppleMailSnapshot) throws -> Header {
        try check()
        let key = row.account + ":" + String(row.id)
        if let cached = headers[key] { return cached }
        // Up to eight candidates can each need a fresh, bounded conversation scan.
        guard headerReads < 12_000 else { throw Failure.budgetExceeded }
        headerReads += 1
        try snapshot.indexFiles(account: row.account)
        let raw = try snapshot.headers(row)
        let names = ["from", "to", "cc", "reply-to", "subject", "date", "message-id", "in-reply-to", "references"]
        let fields = Dictionary(uniqueKeysWithValues: names.map { ($0, AppleMailMIME.prefixUTF8(raw[$0, default: ""], limit: 4_096)) })
        let h = Header(row: row, fields: fields,
                       ids: Self.messageIDs(fields["references", default: ""] + " " + fields["in-reply-to", default: ""])
                           .union(Self.messageIDs(fields["message-id", default: ""])),
                       complete: names.allSatisfy { raw[$0, default: ""].utf8.count <= 4_096 })
        headers[key] = h
        return h
    }
    nonisolated private static func messageIDs(_ text: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"<[^<>\s]+>"#)
        let ns = text as NSString
        return Set(pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
    }

    private func metadata(_ h: Header, _ snapshot: AppleMailSnapshot) -> [String: Any] {
        ["message_ref": reference(h.row, snapshot), "account_ref": h.row.account,
         "date": Self.timestamp(h.row.date), "direction": h.row.sent ? "sent" : "incoming_or_unknown",
         "from": AppleMailMIME.decodedHeader(h.fields["from", default: ""]),
         "to": AppleMailMIME.decodedHeader(h.fields["to", default: ""]),
         "subject": AppleMailMIME.decodedHeader(h.fields["subject", default: ""]), "headers_complete": h.complete]
    }
    nonisolated static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    nonisolated private static func fingerprint(_ message: AppleMailMIME.Message, row: AppleMailRow) -> String {
        let fields = ["from", "to", "cc", "reply-to", "subject", "date", "message-id", "in-reply-to", "references"]
        return AppleMailSource.digest(fields.map { message.headers[$0, default: ""] }.joined(separator: "\u{0}")
            + "\u{0}" + message.text + "\u{0}" + String(message.truncated) + "\u{0}" + String(row.sent))
    }
    private func read(_ row: AppleMailRow, _ snapshot: AppleMailSnapshot) throws -> ([String: Any], MessageEvidence) {
        let h = try header(row, snapshot)
        let message = try snapshot.body(row, preserveContext: true)
        var value = metadata(h, snapshot)
        value["cc"] = AppleMailMIME.decodedHeader(h.fields["cc", default: ""])
        value["reply_to"] = AppleMailMIME.decodedHeader(h.fields["reply-to", default: ""])
        value["body"] = message.text
        value["body_complete"] = !message.truncated
        value["body_truncated"] = message.truncated
        value["continuation_available"] = false
        return (value, MessageEvidence(locator: locator(row, snapshot), fingerprint: Self.fingerprint(message, row: row), complete: !message.truncated && h.complete))
    }

    /// Header relationships, never subject equality, define the conversation. Scan limits and
    /// unavailable headers remain visible; an empty local search never proves server-side absence.
    private func thread(_ seed: AppleMailRow, _ snapshot: AppleMailSnapshot) throws -> Thread {
        let first = try header(seed, snapshot)
        guard !first.ids.isEmpty else { return Thread(rows: [seed], revision: "unknown", complete: false) }
        let eligible = snapshot.rows.filter { !$0.excluded && $0.account == seed.account }.sorted { $0.date > $1.date }
        var pool = [first], complete = eligible.count <= Self.scanLimit && first.complete
        for row in eligible.prefix(Self.scanLimit) where row.id != seed.id {
            do { let h = try header(row, snapshot); pool.append(h); if !h.complete { complete = false } }
            catch let error as Failure { throw error }
            catch is CancellationError { throw CancellationError() }
            catch { complete = false }
        }
        var ids = first.ids, chosen = Set<Int64>([seed.id]), changed = true
        while changed {
            try check(); changed = false
            for h in pool where !chosen.contains(h.row.id) && !h.ids.isDisjoint(with: ids) {
                chosen.insert(h.row.id); ids.formUnion(h.ids); changed = true
            }
        }
        let matches = pool.filter { chosen.contains($0.row.id) }.map(\.row).sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        let revision = AppleMailSource.digest(matches.map { String($0.id) + ":" + $0.messageID }.joined(separator: "\u{0}")
            + ":" + String(complete))
        return Thread(rows: matches, revision: revision, complete: complete)
    }

    /// Returns JSON data only; the MCP layer wraps it. Strict argument checks are also enforced
    /// here because a model can call a tool without respecting its advertised JSON schema.
    func call(_ name: String, arguments: Data) throws -> Data {
        try check()
        guard calls < 40, outputBytes < Self.byteLimit else { throw Failure.budgetExceeded }
        calls += 1
        guard let args = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else { throw Failure.invalidArguments }
        let snapshot = try current()
        var result: [String: Any] = ["snapshot_at": Self.timestamp(snapshotAt), "read_at": Self.timestamp(Date()),
                                   "server_sync": "unknown", "source": "downloaded_apple_mail"]
        var evidence: Evidence?
        switch name {
        case "search_messages":
            guard Set(args.keys).isSubset(of: ["account_ref", "from", "to", "subject", "after", "before", "direction", "offset"]),
                  args.allSatisfy({ $0.key == "offset" || $0.value is String }) else { throw Failure.invalidArguments }
            let offset = try Self.offset(args)
            let account = args["account_ref"] as? String
            guard account == nil || scope.accounts.contains(account!) else { throw Failure.invalidArguments }
            let direction = args["direction"] as? String ?? "any"
            guard ["any", "sent"].contains(direction) else { throw Failure.invalidArguments }
            let after = try Self.date(args["after"], fallback: Date().addingTimeInterval(-90 * 86_400))
            let before = try Self.date(args["before"], fallback: Date())
            guard after <= before else { throw Failure.invalidArguments }
            let rows = snapshot.rows.filter { !$0.excluded && (account == nil || $0.account == account!)
                && $0.date >= after && $0.date <= before && (direction == "any" || $0.sent) }.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
            var values: [[String: Any]] = [], unavailable = 0, clipped = 0
            for row in rows.prefix(Self.scanLimit) {
                do {
                    let h = try header(row, snapshot)
                    if !h.complete { clipped += 1 }
                    if ["from", "to", "subject"].allSatisfy({ key in
                        guard let filter = args[key] as? String else { return true }
                        return AppleMailMIME.decodedHeader(h.fields[key, default: ""]).localizedCaseInsensitiveContains(filter)
                    }) { values.append(metadata(h, snapshot)) }
                } catch let error as Failure { throw error }
                catch is CancellationError { throw CancellationError() }
                catch { unavailable += 1 }
            }
            result["messages"] = Array(values.dropFirst(offset).prefix(20))
            result["next_offset"] = offset + 20 < values.count ? offset + 20 as Any : NSNull()
            result["local_coverage_complete"] = rows.count <= Self.scanLimit && unavailable == 0 && clipped == 0
            result["unavailable_headers"] = unavailable
            result["truncated_headers"] = clipped
            result["after"] = Self.timestamp(after); result["before"] = Self.timestamp(before)
        case "read_messages", "read_thread":
            let rows: [AppleMailRow], threadInfo: Thread?, seed: AppleMailRow?
            if name == "read_thread" {
                guard Set(args.keys) == ["message_ref"], let ref = args["message_ref"] as? String else { throw Failure.invalidArguments }
                let row = try resolve(ref, in: snapshot)
                let found = try thread(row, snapshot)
                seed = row; threadInfo = found
                // Keep the newest context AND the original request within the bounded response.
                var selected = Array(found.rows.suffix(10))
                if !selected.contains(where: { $0.id == row.id }) { selected = [row] + selected.suffix(9) }
                rows = selected
                result["omitted_messages"] = found.rows.count - rows.count
            } else {
                guard Set(args.keys) == ["message_refs"], let refs = args["message_refs"] as? [String],
                      !refs.isEmpty, refs.count <= 5, Set(refs).count == refs.count else { throw Failure.invalidArguments }
                rows = try refs.map { try resolve($0, in: snapshot) }; seed = nil; threadInfo = nil
            }
            var values: [[String: Any]] = [], proofs: [MessageEvidence] = []
            for row in rows {
                do {
                    let (value, proof) = try read(row, snapshot); values.append(value); proofs.append(proof)
                } catch let error as Failure { throw error }
                catch is CancellationError { throw CancellationError() }
                catch { values.append(["message_ref": reference(row, snapshot), "error": "message_unavailable"]) }
            }
            guard !proofs.isEmpty else { throw Failure.unavailable }
            let complete = proofs.count == rows.count && proofs.allSatisfy(\.complete)
                && (threadInfo.map { $0.complete && $0.rows.count == rows.count } ?? true)
            let id = "mail-read:" + UUID().uuidString
            evidence = Evidence(id: id, scope: scope, readAt: Date(), messages: proofs,
                threadSeed: seed.map { locator($0, snapshot) }, threadRevision: threadInfo?.revision, localCoverageComplete: complete)
            result["messages"] = values; result["evidence_ref"] = id; result["local_coverage_complete"] = complete
        default: throw Failure.invalidArguments
        }
        try check()
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        guard outputBytes + data.count <= Self.byteLimit else { throw Failure.budgetExceeded }
        outputBytes += data.count
        if let evidence { issued[evidence.id] = evidence }
        return data
    }

    func evidence(_ ids: [String]) throws -> [Evidence] {
        try check()
        guard ids.count <= 40, Set(ids).count == ids.count else { throw Failure.invalidArguments }
        return try ids.map { guard let value = issued[$0] else { throw Failure.unknownReference }; return value }
    }
    func covers(_ sourceReferences: [String], with evidence: [Evidence]) throws -> Bool {
        try check()
        return sourceReferences.allSatisfy { reference in
            guard let locator = references[reference] else { return false }
            return evidence.contains { $0.messages.contains { $0.locator == locator } }
        }
    }
    func validate(_ evidence: [Evidence]) throws -> Bool {
        let snapshot = try current(refresh: true)
        guard !evidence.isEmpty else { return false }
        for proof in evidence {
            guard proof.scope == scope, !proof.messages.isEmpty else { return false }
            for message in proof.messages {
                let row = try resolve(message.locator, in: snapshot)
                let (_, fresh) = try read(row, snapshot)
                guard fresh == message else { return false }
            }
            if let seed = proof.threadSeed {
                let fresh = try thread(resolve(seed, in: snapshot), snapshot)
                guard fresh.revision == proof.threadRevision else { return false }
            }
        }
        try check(); return true
    }
    nonisolated private static func offset(_ args: [String: Any]) throws -> Int {
        guard let value = args["offset"] else { return 0 }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let n = value as? Int, (0...scanLimit).contains(n) else { throw Failure.invalidArguments }
        return n
    }
    nonisolated private static func date(_ value: Any?, fallback: Date) throws -> Date {
        guard let value else { return fallback }
        guard let text = value as? String, let date = ISO8601DateFormatter().date(from: text) else { throw Failure.invalidArguments }
        return date
    }
}
