#!/usr/bin/env python3
"""Exercise complete production attention policy + real isolated SQLite read receipts.

No AppKit windows, provider calls, production defaults, timers or credentials. Retraction
tests use the same identity/generation predicate as the coordinator's real delayed task.
"""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sentient OS macOS/Notch Magic"

FIXTURE = r'''
import Foundation

typealias Policy = SidekickAttentionPolicy
typealias Store = SidekickConversationStore
typealias Event = SidekickConversationEvent

@main enum AttentionTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { fatalError("FAIL: " + label) }
        checks += 1
    }

    struct Surface {
        var policy: Policy
        var visible = false
        var home = false
        var blocked = false

        init(_ store: Store) throws {
            policy = Policy(generation: try store.generation, latestSequence: try store.latestSequence)
        }

        @discardableResult mutating func refresh(_ store: Store) throws -> Policy.Decision {
            let high = try store.latestUnreadHighPriorityMessage
            let result = policy.update(generation: try store.generation, latestSequence: try store.latestSequence,
                latestUnreadHigh: high.map { .init(id: $0.event.id, sequence: $0.sequence) },
                homeVisible: home, inputBlocked: blocked, previewVisible: visible)
            switch result {
            case .present: visible = true
            case .dismiss: visible = false
            case .unchanged: break
            }
            return result
        }

        mutating func dismiss() { visible = false; policy.dismiss() }
    }

    static func task(_ store: Store) throws -> UUID {
        let id = UUID()
        try store.appendBatch([
            Event(taskID: id, kind: .taskStarted, text: "fixture task"),
            Event(taskID: id, kind: .userMessage, text: "fixture request", source: "promptBar")
        ])
        return id
    }

    static func high(_ id: String, taskID: UUID, store: Store) throws -> Policy.Message {
        let record = try store.append(Event(id: id, taskID: taskID, kind: .assistantMessage,
            text: "A durable fixture response", priority: .high))
        return .init(id: record.event.id, sequence: record.sequence)
    }

    static func editing(_ directory: URL) throws {
        let store = try Store(url: directory.appendingPathComponent("editing.sqlite"))
        let taskID = try task(store)
        var surface = try Surface(store)
        let first = try high("editing-first", taskID: taskID, store: store)
        try check(try surface.refresh(store) == .present(first), "editing fixture presents a response")
        try check(surface.policy.setEditing(true) && surface.policy.isEditing && surface.policy.isInteracting,
            "focusing reply editor becomes active interaction")
        try check(!surface.policy.setEditing(true), "unchanged editor state does not reschedule timers")
        try check(!surface.policy.canRetract(generation: try store.generation, messageID: first.id, previewVisible: true),
            "already scheduled timer cannot retract while reply editor is active")
        surface.policy.setHovering(true)
        surface.policy.setHovering(false)
        try check(surface.policy.isInteracting, "pointer exit cannot discard a focused editor or unsent draft")
        let second = try high("editing-second", taskID: taskID, store: store)
        try check(try surface.refresh(store) == .unchanged && surface.policy.pending == second,
            "incoming message cannot replace response while composing a reply")
        let third = try high("editing-third", taskID: taskID, store: store)
        try check(try surface.refresh(store) == .unchanged && surface.policy.pending == third && surface.policy.presented == first,
            "reply editing coalesces incoming messages without replacing the reply source")
        surface.policy.setSelecting(true)
        try check(surface.policy.setEditing(false) && !surface.policy.isEditing && surface.policy.isInteracting,
            "ending reply editing preserves independent text selection")
        try check(try surface.refresh(store) == .unchanged, "selection still holds the preview after editing ends")
        surface.policy.setSelecting(false)
        try check(try surface.refresh(store) == .present(third), "releasing all interaction presents only the newest deferred message")
        try check(!surface.policy.canRetract(generation: try store.generation, messageID: first.id, previewVisible: true),
            "old preview timer cannot retract replacement after editing releases")
        try check(surface.policy.canRetract(generation: try store.generation, messageID: third.id, previewVisible: true),
            "replacement can retract normally after editing ends")

        surface.policy.setEditing(true)
        try store.markRead(messageIDs: [second.id, third.id], expectedGeneration: store.generation)
        try check(try surface.refresh(store) == .dismiss && !surface.policy.isEditing && !surface.policy.isInteracting,
            "reading the preview elsewhere clears reply editing state")
        let beforeHome = try high("editing-home", taskID: taskID, store: store)
        try surface.refresh(store)
        surface.policy.setEditing(true)
        _ = try high("editing-home-pending", taskID: taskID, store: store)
        try surface.refresh(store)
        surface.home = true
        try check(try surface.refresh(store) == .dismiss && !surface.policy.isEditing && surface.policy.pending == nil,
            "opening Home releases editor hold and consumes deferred preview attention")
        surface.home = false
        try check(try surface.refresh(store) == .unchanged, "closing Home does not reopen an abandoned reply preview")
        try check(!surface.policy.canRetract(generation: try store.generation, messageID: beforeHome.id, previewVisible: true),
            "Home handoff invalidates the editor preview's old timer")

        let beforePhase = try high("editing-phase", taskID: taskID, store: store)
        try surface.refresh(store)
        surface.policy.setEditing(true)
        surface.visible = false; surface.blocked = true
        try check(try surface.refresh(store) == .unchanged && !surface.policy.isEditing && surface.policy.presented == nil,
            "another notch phase clears editing together with its hidden preview")
        try check(!surface.policy.canRetract(generation: try store.generation, messageID: beforePhase.id, previewVisible: true),
            "hidden edited preview cannot be retracted by a stale callback")
        surface.blocked = false
        _ = try high("editing-dismiss", taskID: taskID, store: store)
        try surface.refresh(store)
        surface.policy.setEditing(true)
        surface.dismiss()
        try check(!surface.policy.isEditing && !surface.policy.isInteracting, "explicit dismissal releases reply editing state")

        let beforeReset = try high("editing-reset", taskID: taskID, store: store)
        try surface.refresh(store)
        surface.policy.setEditing(true)
        let generation = try store.generation
        try store.reset()
        try check(try surface.refresh(store) == .dismiss && !surface.policy.isEditing && !surface.policy.isInteracting,
            "clearing chat resets active reply editing state")
        try check(!surface.policy.canRetract(generation: generation, messageID: beforeReset.id, previewVisible: true),
            "pre-clear edited preview timer cannot affect a new conversation")
    }

    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try editing(directory)
        let store = try Store(url: directory.appendingPathComponent("history.sqlite"))
        let taskID = try task(store)
        let historic = try high("historic", taskID: taskID, store: store)
        var surface = try Surface(store)
        try check(try surface.refresh(store) == .unchanged, "launch does not replay historic unread high messages")
        try check(try store.unreadCount == 1, "suppressing old attention does not mark it read")

        let first = try high("first", taskID: taskID, store: store)
        try check(try surface.refresh(store) == .present(first), "new high message presents immediately")
        try check(try surface.refresh(store) == .unchanged, "refresh does not duplicate presentation")
        try check(surface.policy.canRetract(generation: try store.generation,
            messageID: first.id, previewVisible: true), "timer recognizes the current preview")
        try check(!surface.policy.canRetract(generation: UUID(),
            messageID: first.id, previewVisible: true), "old generation timer cannot retract")
        try check(!surface.policy.canRetract(generation: try store.generation,
            messageID: historic.id, previewVisible: true), "old message timer cannot retract")

        surface.policy.setHovering(true)
        try check(!surface.policy.canRetract(generation: try store.generation,
            messageID: first.id, previewVisible: true), "hover pauses retraction")
        let second = try high("second", taskID: taskID, store: store)
        try check(try surface.refresh(store) == .unchanged, "new high does not replace hovered response")
        try check(surface.policy.pending == second, "hover retains one pending response")
        let third = try high("third", taskID: taskID, store: store)
        try check(try surface.refresh(store) == .unchanged, "newer high remains deferred during hover")
        try check(surface.policy.pending == third, "pending attention coalesces to latest high")
        surface.policy.setSelecting(true)
        surface.policy.setHovering(false)
        try check(surface.policy.isInteracting, "cursor exit cannot overwrite active text selection")
        try check(try surface.refresh(store) == .unchanged, "selection also defers newer responses")
        surface.policy.setSelecting(false)
        try check(try surface.refresh(store) == .present(third), "last interaction exit presents latest without old timer delay")
        try check(!surface.policy.canRetract(generation: try store.generation,
            messageID: first.id, previewVisible: true), "previous preview timer cannot retract replacement")

        surface.policy.setHovering(true)
        let readPending = try high("read-pending", taskID: taskID, store: store)
        try surface.refresh(store)
        try store.markRead(messageIDs: [readPending.id], expectedGeneration: store.generation)
        surface.policy.setHovering(false)
        try check(try surface.refresh(store) == .unchanged, "reading pending response elsewhere cancels deferred popup")
        try check(surface.policy.pending == nil && surface.policy.presented == third, "read pending record does not replace visible response")
        try store.markRead(messageIDs: [third.id], expectedGeneration: store.generation)
        try check(try surface.refresh(store) == .dismiss, "reading current preview dismisses it even if older unread records remain")

        surface.home = true
        let whileHome = try high("while-home", taskID: taskID, store: store)
        try check(try surface.refresh(store) == .unchanged, "visible Home suppresses new popup")
        try check(surface.policy.observedThrough >= whileHome.sequence, "suppressed events still advance observed cursor")
        surface.home = false
        try check(try surface.refresh(store) == .unchanged, "closing Home does not replay its unread messages")
        try check(try store.latestUnreadHighPriorityMessage?.event.id == whileHome.id, "suppression does not create a false read receipt")
        let next = try high("next", taskID: taskID, store: store)
        try check(try surface.refresh(store) == .present(next), "genuinely new message after Home closes still presents")
        surface.home = true
        try check(try surface.refresh(store) == .dismiss, "opening Home closes an already visible preview")
        surface.home = false
        try check(try surface.refresh(store) == .unchanged, "closing Home cannot reopen dismissed preview")

        surface.blocked = true
        let duringTyping = try high("during-typing", taskID: taskID, store: store)
        try check(try surface.refresh(store) == .unchanged, "active typing keeps ownership of notch")
        try check(surface.policy.pending == duringTyping, "typing defers instead of discarding new high message")
        let afterTyping = try high("latest-during-typing", taskID: taskID, store: store)
        try surface.refresh(store)
        surface.blocked = false
        try check(try surface.refresh(store) == .present(afterTyping), "leaving typing presents only latest pending response")
        surface.dismiss()

        surface.blocked = true
        let duringQuestion = try high("during-question", taskID: taskID, store: store)
        try store.append(Event(id: "question", taskID: taskID, kind: .question,
            text: "Choose an option", priority: .high, choices: ["Left", "Right"]))
        try store.append(Event(id: "ordinary-answer", taskID: taskID, kind: .assistantMessage,
            text: "An ordinary response", messageKind: .answer, priority: .normal))
        try check(try store.latestUnreadHighPriorityMessage?.event.id == duringQuestion.id,
            "later normal answer and high question cannot mask the message-specific query")
        try check(try surface.refresh(store) == .unchanged, "pending question/retry takes precedence over high message")
        try store.append(Event(taskID: taskID, kind: .answer, text: "Left", reply: .init(messageID: "question")))
        surface.blocked = false
        try check(try surface.refresh(store) == .present(duringQuestion), "resolution delivers deferred high message")

        surface.policy.setHovering(true)
        _ = try high("close-with-pending", taskID: taskID, store: store)
        try surface.refresh(store)
        surface.dismiss()
        try check(try surface.refresh(store) == .unchanged, "explicit dismissal consumes pending previews without a popup loop")
        try check(!surface.policy.isInteracting && surface.policy.pending == nil, "dismissal releases interaction state")

        let beforeReset = try high("before-reset", taskID: taskID, store: store)
        try surface.refresh(store)
        let oldGeneration = try store.generation
        try store.reset()
        try check(try surface.refresh(store) == .dismiss, "generation change clears an old visible preview")
        try check(surface.policy.presented == nil && surface.policy.pending == nil, "reset clears retained message identities")
        try check(!surface.policy.canRetract(generation: oldGeneration,
            messageID: beforeReset.id, previewVisible: true), "pre-reset timer cannot retract new generation")
        let freshTask = try task(store)
        let afterReset = try high("after-reset", taskID: freshTask, store: store)
        try check(afterReset.sequence < beforeReset.sequence, "fixture exercises sequence restart after reset")
        try check(try surface.refresh(store) == .present(afterReset), "new lower sequence presents after reset")
        let reopened = try Store(url: store.url)
        var relaunched = try Surface(reopened)
        try check(try relaunched.refresh(reopened) == .unchanged, "app relaunch baselines saved unread history")

        // Exercise the handoff where a record commits between separate sequence/query reads.
        var race = Policy(generation: oldGeneration, latestSequence: 0)
        let ahead = Policy.Message(id: "committed-between-reads", sequence: 2)
        try check(race.update(generation: oldGeneration, latestSequence: 1, latestUnreadHigh: ahead,
            homeVisible: false, inputBlocked: false, previewVisible: false) == .present(ahead), "record arriving between reads presents once")
        try check(race.update(generation: oldGeneration, latestSequence: 2, latestUnreadHigh: ahead,
            homeVisible: false, inputBlocked: false, previewVisible: true) == .unchanged, "cursor also consumes captured record sequence")
        _ = race.update(generation: oldGeneration, latestSequence: 2, latestUnreadHigh: ahead,
            homeVisible: false, inputBlocked: true, previewVisible: false)
        try check(race.presented == nil, "another phase drops the prior visible preview identity")
        try check(!race.canRetract(generation: oldGeneration, messageID: ahead.id, previewVisible: true),
            "phase transition invalidates timer even if a later message phase opens")
        print("PASS: \(checks) Sidekick attention checks")
    }
}
'''


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="sentient-attention-test-") as temporary:
        directory = Path(temporary)
        fixture = directory / "AttentionTests.swift"
        fixture.write_text(FIXTURE)
        executable = directory / "attention-tests"
        subprocess.run([
            "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
            "-strict-concurrency=complete", "-warnings-as-errors", "-parse-as-library",
            str(SOURCE / "SidekickConversationStore.swift"),
            str(SOURCE / "SidekickAttentionPolicy.swift"), str(fixture), "-o", str(executable),
        ], check=True, timeout=60)
        subprocess.run([str(executable), str(directory)], check=True, timeout=20)


if __name__ == "__main__":
    main()
