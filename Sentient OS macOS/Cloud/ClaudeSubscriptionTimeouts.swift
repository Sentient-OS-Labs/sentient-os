// Execution may be unlimited while individual bridge requests retain finite idle budgets.
// In particular, adding cleanup/question grace must never turn zero into a task deadline.
import Foundation

nonisolated struct ClaudeSubscriptionTimeouts: Sendable {
    let childExecution: TimeInterval
    let helperExecution: TimeInterval
    let transport: TimeInterval

    init(execution: TimeInterval, waitingAllowance: TimeInterval) {
        precondition(execution.isFinite && execution >= 0 && waitingAllowance.isFinite && waitingAllowance >= 0)
        // Thirty minutes bounds a stalled single bridge request, not a progressing task.
        transport = (execution == 0 ? 1_800 : execution) + waitingAllowance
        childExecution = execution == 0 ? 0 : transport
        helperExecution = execution == 0 ? 0 : execution + 5
    }

    var transportMilliseconds: Int {
        // Claude's timers are milliseconds. Keep conversions within a signed 32-bit timer
        // even if a future caller supplies a much larger finite background execution budget.
        Int(min(transport, TimeInterval(Int32.max) / 1_000) * 1_000)
    }
}
