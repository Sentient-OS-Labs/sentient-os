//
//  MailConnector.swift
//  Sentient OS macOS
//
//  Apple Mail adapter for the iterative core. A SINGLE bucket ("mail"), keyed on
//  (receivedDate, "mail:<rowid>") — received-date so a re-delivered message is NOT
//  re-summarized; the rowid is the tiebreak. One email = one item, through the MAIL
//  Triage prompt (sender + subject + metadata — the model judges from envelope data,
//  same as the Gmail connector's snippet pass). Wraps AppleMailSource.eligibleEmails
//  (WAL-safe read + FK resolution + cap); the metadata text is already built at list
//  time, so `load` just wraps it. Requires Full Disk Access.
//

import Foundation

struct MailConnector: Connector {
    let kind = SourceKind.appleMail

    func buckets(since marks: [String: ItemKey]) throws -> [Bucket] {
        let items = try AppleMailSource().eligibleEmails().map { c in
            (key: ItemKey(date: c.itemDate, tiebreak: c.id), item: c)   // c.id = "mail:<rowid>" (unique)
        }
        return [Bucket(key: "mail", items: items)]   // single bucket, newest-received first
    }

    func load(_ item: Candidate) throws -> Artifact {
        Artifact(candidate: item, text: item.metadata["emailText"] ?? "")
    }
}
