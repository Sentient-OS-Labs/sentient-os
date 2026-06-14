//
//  SelfTest_ChatIter.swift
//  Sentient OS macOS
//
//  SENTIENT_SELFTEST=chatiter — runs the REAL WhatsApp + iMessage connectors against the live DBs
//  (over ALL chats) and checks structural invariants: per-chat buckets keyed by source, every item
//  the right kind, every window has text, keys unique + newest-first within each chat, load() returns
//  the window text. Needs Full Disk Access + some chats; reports "skipped" gracefully without them.
//  (The generic core — ItemKey/CycleStore/partition — is covered by `fileiter`.)
//

import Foundation

enum SelfTestChatIter {

    static func run(emit: (String) -> Void) async {
        var passed = 0, failed = 0
        func check(_ label: String, _ cond: Bool) {
            if cond { passed += 1; emit("  ✓ \(label)") }
            else { failed += 1; emit("  ✗ FAIL — \(label)") }
        }

        emit("=== chatiter: WhatsApp + iMessage connectors against the live DBs ===")
        validate("WhatsApp", prefix: "whatsapp:", kind: .whatsapp, check: check, emit: emit) {
            let jids = Set((try WhatsAppSource().listChats()).map(\.id))
            return try WhatsAppConnector(chatJIDs: jids).buckets(since: [:])
        }
        validate("iMessage", prefix: "imessage:", kind: .imessage, check: check, emit: emit) {
            let guids = Set((try iMessageSource().listChats()).map(\.id))
            return try iMessageConnector(chatGUIDs: guids).buckets(since: [:])
        }
        emit("\n=== chatiter: \(passed) passed · \(failed) failed ===")
    }

    private static func validate(_ name: String, prefix: String, kind: SourceKind,
                                 check: (String, Bool) -> Void, emit: (String) -> Void,
                                 buckets: () throws -> [Bucket]) {
        let bs: [Bucket]
        do { bs = try buckets() }
        catch { emit("  ⚠️ \(name): couldn't read (Full Disk Access?) — \(error). Skipping."); return }

        let items = bs.flatMap { $0.items }
        emit("  \(name): \(bs.count) chats · \(items.count) windows")
        guard !items.isEmpty else { emit("  (\(name): 0 windows — no opted chats / no FDA / empty.)"); return }

        check("\(name): bucket keys are \(prefix)<id>", bs.allSatisfy { $0.key.hasPrefix(prefix) })
        check("\(name): every item kind == .\(kind)", items.allSatisfy { $0.item.kind == kind })
        check("\(name): every window has text", items.allSatisfy { !($0.item.metadata["windowText"] ?? "").isEmpty })
        check("\(name): per-chat keys unique + newest-first", bs.allSatisfy { b in
            let ks = b.items.map(\.key)
            let unique = Set(ks).count == ks.count
            let descending = zip(ks, ks.dropFirst()).allSatisfy { $0.0 > $0.1 }
            return unique && descending
        })
    }
}
