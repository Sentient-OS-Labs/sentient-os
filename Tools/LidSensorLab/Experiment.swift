import Foundation

struct ExperimentPlan: Sendable {
    enum Mode: String, CaseIterable, Sendable { case lid, ambient, fusion, tapping, missedTaps }
    enum ManualAction: String, CaseIterable, Sendable {
        case missedTaps, deskTaps, typing, handRest
        var label: String {
            switch self {
            case .missedTaps: "Missed notch taps"
            case .deskTaps: "Desk taps (control)"
            case .typing: "Firm typing (control)"
            case .handRest: "Lift / rest hand (control)"
            }
        }
        var title: String {
            switch self {
            case .missedTaps: "TAP THREE TIMES"
            case .deskTaps: "TAP THE DESK THREE TIMES"
            case .typing: "TYPE NORMALLY, THEN FIRMLY"
            case .handRest: "LIFT AND REST YOUR HAND"
            }
        }
        var instruction: String {
            switch self {
            case .missedTaps: "Near the notch, but away from the light sensor."
            case .deskTaps: "Three ordinary desk knocks. Keep your hands away from the screen."
            case .typing: "Type in the box for about five seconds. The text is not saved."
            case .handRest: "Lift your hand off the laptop and rest it back, three times. Do not touch the screen."
            }
        }
    }
    enum Kind: String, Sendable {
        case tap, handPass, hover, lighting, desk, typing, coincidence
        var title: String {
            switch self {
            case .tap: "TAP THE NOTCH"
            case .handPass: "PASS YOUR HAND"
            case .hover: "HOVER, DON’T TOUCH"
            case .lighting: "CHANGE THE SHADOW"
            case .desk: "TAP THE DESK"
            case .typing: "TYPE FIRMLY"
            case .coincidence: "PASS + DESK TAP"
            }
        }
        var instruction: String {
            switch self {
            case .tap: "One normal tap near the notch, then move your hand away."
            case .handPass: "Pass a finger close across the notch once, without touching it."
            case .hover: "Hold a finger close to the notch without touching. Withdraw when HOLD STILL appears."
            case .lighting: "Lean sideways or back to change the broad room shadow. Keep hands away from the display."
            case .desk: "Tap the desk once. Keep hands away from the display."
            case .typing: "Type abc a few times, a little firmly. The text is not saved."
            case .coincidence: "Pass one finger near the notch WITHOUT touching. At the same time, tap the desk with your other hand."
            }
        }
    }
    var mode = Mode.lid
    var quietSeconds = 5.0
    var spacing = 4.0
    var taps = 6
    var trials: [Kind] {
        switch mode {
        case .missedTaps: []
        case .lid: Array(repeating: .tap, count: taps)
        case .tapping: Array(repeating: .tap, count: 10)
        case .ambient: [.tap, .handPass, .tap, .hover, .lighting, .desk, .tap, .typing, .handPass, .lighting, .tap, .hover]
        case .fusion: [.tap, .handPass, .desk, .tap, .hover, .lighting, .tap, .typing, .coincidence, .tap, .handPass, .hover, .tap, .lighting, .coincidence, .tap]
        }
    }
    var isManual: Bool { mode == .missedTaps }
    var tapsOnly: Bool { mode == .lid || mode == .tapping }
    var recordsMotion: Bool { mode == .fusion || mode == .tapping || isManual }
    var actionSeconds: Double { tapsOnly ? 0.75 : 2 }
    var trialLength: Double { tapsOnly ? spacing : 8 }
    var preparationSeconds: Double { tapsOnly ? 0 : 2 }
    var duration: Double { isManual ? .infinity : quietSeconds + Double(trials.count) * trialLength }
    var targetTapCount: Int { isManual ? 3 : trials.filter { $0 == .tap }.count }
    func cueTime(_ index: Int) -> Double { quietSeconds + Double(index) * trialLength + preparationSeconds }
    func trialIndex(at elapsed: Double) -> Int? {
        guard !isManual, elapsed >= quietSeconds, elapsed < duration else { return nil }
        return min(trials.count-1, Int((elapsed-quietSeconds)/trialLength))
    }
    enum Phase: Equatable {
        case manual, quiet(Int), tap(Int), prepare(Int), action(Int), wait(seconds: Int, next: Int?), done
        var cueIndex: Int? {
            switch self { case .tap(let index), .action(let index): index; default: nil }
        }
    }
    func phase(at elapsed: Double) -> Phase {
        if isManual { return .manual }
        guard elapsed < duration else { return .done }
        if elapsed < quietSeconds { return .quiet(Int(ceil(quietSeconds - max(0, elapsed)))) }
        let index = trialIndex(at: elapsed)!
        let within = elapsed - quietSeconds - Double(index)*trialLength
        if !tapsOnly {
            if within < 2 { return .prepare(index + 1) }
            if within < 4 { return .action(index + 1) }
        } else if within < 0.75 { return .tap(index + 1) }
        return .wait(seconds: max(1, Int(ceil(trialLength - within))), next: index + 1 < trials.count ? index + 2 : nil)
    }
}
