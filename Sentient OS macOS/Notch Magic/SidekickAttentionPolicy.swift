// Presentation bookkeeping only. Durable unread state belongs to the conversation store.
// Keeping this independent of views and clocks makes dismissal, coalescing and reset races
// testable without opening a window or marking a message read.
import Foundation

struct SidekickAttentionPolicy {
    struct Message: Equatable {
        let id: String
        let sequence: Int64
    }

    enum Decision: Equatable {
        case unchanged
        case dismiss
        case present(Message)
    }

    private(set) var generation: UUID?
    private(set) var observedThrough: Int64
    private(set) var pending: Message?
    private(set) var presented: Message?
    private(set) var isHovering = false
    private(set) var isSelecting = false
    private(set) var isEditing = false
    var isInteracting: Bool { isHovering || isSelecting || isEditing }

    init(generation: UUID?, latestSequence: Int64) {
        self.generation = generation
        observedThrough = max(0, latestSequence)
    }

    /// `latestUnreadHigh` comes from a query filtered by kind, priority and read receipts
    /// before LIMIT. A later ordinary answer or question must not hide a high message.
    mutating func update(generation: UUID?, latestSequence: Int64,
                         latestUnreadHigh: Message?, homeVisible: Bool,
                         inputBlocked: Bool, previewVisible: Bool) -> Decision {
        guard generation == self.generation else {
            let dismiss = previewVisible
            self.generation = generation
            observedThrough = max(0, latestSequence)
            self.dismiss()
            return dismiss ? .dismiss : .unchanged
        }
        let previousSequence = observedThrough
        observedThrough = max(observedThrough, latestSequence, latestUnreadHigh?.sequence ?? 0)

        // Suppression consumes the presentation opportunity, not the durable unread state.
        // Closing Home later must not cause a delayed notification for what arrived there.
        if homeVisible || generation == nil {
            dismiss()
            return previewVisible ? .dismiss : .unchanged
        }

        // A phase change (typing, a question, a new task) can hide the preview independently.
        // It was already presented, so it must never be requeued by that phase change.
        if !previewVisible, presented != nil {
            presented = nil
            isHovering = false
            isSelecting = false
            isEditing = false
        }

        // A viewport receipt may have consumed a deferred message. Revalidate against the
        // current query rather than retaining a record captured before the user read it.
        if pending != latestUnreadHigh { pending = nil }
        if let latestUnreadHigh, latestUnreadHigh.sequence > previousSequence {
            pending = latestUnreadHigh
        }

        let visibleWasRead = previewVisible && presented.map {
            (latestUnreadHigh?.sequence ?? 0) < $0.sequence
        } == true
        if visibleWasRead {
            presented = nil
            isHovering = false
            isSelecting = false
            isEditing = false
        }

        if !inputBlocked, !isInteracting, let pending {
            self.pending = nil
            presented = pending
            return .present(pending)
        }
        return visibleWasRead ? .dismiss : .unchanged
    }

    @discardableResult mutating func setHovering(_ value: Bool) -> Bool {
        guard isHovering != value else { return false }
        isHovering = value
        return true
    }

    @discardableResult mutating func setSelecting(_ value: Bool) -> Bool {
        guard isSelecting != value else { return false }
        isSelecting = value
        return true
    }

    /// The reply editor remains active while focused or while it contains an unsent draft.
    /// Its owner supplies that combined state, independently of pointer hover and selection.
    @discardableResult mutating func setEditing(_ value: Bool) -> Bool {
        guard isEditing != value else { return false }
        isEditing = value
        return true
    }

    /// An explicit close consumes pending attention too. It never mutates read receipts.
    mutating func dismiss() {
        pending = nil
        presented = nil
        isHovering = false
        isSelecting = false
        isEditing = false
    }

    func canRetract(generation: UUID?, messageID: String?, previewVisible: Bool) -> Bool {
        generation == self.generation && messageID != nil && messageID == presented?.id
            && previewVisible && !isInteracting
    }
}
