// Enforces the process budget in active seconds, excluding time spent awaiting a notch reply.
// Uses a monotonic clock and cancels its timer when the owned process finishes.
// Doc: Documentation - Cloud - CodexCLI (the codex exec spine).md
import Foundation
import os

nonisolated final class RunWatchdog: Sendable {
    private let timer: DispatchSourceTimer
    private let finished = OSAllocatedUnfairLock(initialState: false)
    init(timeout: TimeInterval, interaction: SidekickInteraction?, onTimeout: @escaping @Sendable () -> Void) {
        let began = ProcessInfo.processInfo.systemUptime
        let waitingAtStart = interaction?.waitingSeconds ?? 0
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        if interaction == nil { timer.schedule(deadline: .now() + timeout) }
        else { timer.schedule(deadline: .now() + min(timeout, 0.25), repeating: 0.25) }
        timer.setEventHandler { [finished] in
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            let waiting = (interaction?.waitingSeconds ?? 0) - waitingAtStart
            guard elapsed - waiting >= timeout else { return }
            finished.withLock { done in
                guard !done else { return }
                done = true; onTimeout()
            }
        }
        timer.resume()
    }
    func cancel() { finished.withLock { $0 = true }; timer.cancel() }
    deinit { timer.cancel() }
}
