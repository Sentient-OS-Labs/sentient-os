import Foundation

@main struct PhysicalTapTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
        checks += 1
    }
    static func replay(_ values: [Double], interval: Double = 0.2, resetAt: Int? = nil,
                       pulseTimes: [Double]? = nil, accelEnabled: Bool = true,
                       gyroEnabled: Bool = true, motionStopsAt: Double = .infinity) -> [Double] {
        var detector = PhysicalTapDetector()
        detector.reset(at: 0)
        let pulses = pulseTimes ?? values.indices.dropFirst().filter {
            values[$0] < values[$0 - 1] * 0.8
        }.map { Double($0) * interval - 0.05 }
        var hits: [Double] = []
        var motionSample = 0
        for (index, lux) in values.enumerated() {
            let time = Double(index) * interval
            if index == resetAt { detector.reset(at: time) }
            while Double(motionSample) / 800 <= time {
                let stamp = Double(motionSample) / 800
                let vibration = pulses.reduce(0.0) { total, pulse in
                    let age = stamp - pulse
                    guard age >= 0, age < 0.075 else { return total }
                    return total + sin(age * 2 * .pi * 90) * exp(-age / 0.025)
                }
                if stamp <= motionStopsAt {
                    if accelEnabled { detector.accel(SIMD3(vibration * 0.02, 0, 1), at: stamp) }
                    if gyroEnabled { detector.gyro(SIMD3(0, vibration * 2, 0), at: stamp) }
                }
                motionSample += 1
            }
            if detector.light(lux, at: time) { hits.append(time) }
        }
        return hits
    }
    static func main() {
        check(replay([100, 20, 100]).count == 1, "light plus motion recognizes a tap")
        check(replay([100, 20, 100], pulseTimes: []).isEmpty, "light without vibration is rejected")
        check(replay([100, 20, 100], accelEnabled: false).isEmpty, "missing accelerometer blocks taps")
        check(replay([100, 20, 100], gyroEnabled: false).isEmpty, "missing gyroscope blocks taps")
        check(replay([100, 20, 100], motionStopsAt: 0.2).isEmpty, "stale motion blocks optical recovery")
        check(replay([100, 100, 100, 100], pulseTimes: [0.15, 0.35]).isEmpty, "motion without a light pulse is rejected")
        check(replay([100, 20, 20, 100], pulseTimes: [0.5]).isEmpty, "late hand-rest impact cannot corroborate an earlier dip")
        check(replay([100, 20]).isEmpty, "recognition waits for light recovery")
        check(replay([100, 20, 100, 20, 100]).count == 2, "consecutive 400 ms taps have no added delay")
        check(replay([100, 20, 100], interval: 0.1).first == 0.2, "startup has no one-second hold")
        check(replay([100, 20, 100, 20, 100], interval: 0.1).count == 1, "200 ms duplicate is debounced")
        check(replay([100, 20, 100, 20, 100, 20, 100], interval: 0.1).count == 2, "ignored duplicates do not extend the debounce")
        check(replay([100, 20, 100, 20, 100], interval: 0.16).count == 2, "320 ms deliberate second tap works")
        let repeated = [100.0] + (0..<12).flatMap { _ in [20.0, 100.0] }
        let firstThreePulses = [0.15, 0.55, 0.95]
        check(replay(repeated, pulseTimes: firstThreePulses).count == 3, "later light-only taps never bypass motion verification")
        let firstThreeLightPulses = [100.0, 20, 100, 20, 100, 20, 100] + Array(repeating: 100.0, count: 18)
        let manyImpacts = (0..<12).map { 0.15 + Double($0) * 0.4 }
        check(replay(firstThreeLightPulses, pulseTimes: manyImpacts).count == 3, "later motion-only impacts never unlock fast mode")
        check(replay(repeated).count == 12, "every tap continues to require its own optical pulse")
        check(replay(Array(repeating: 100, count: 30)).isEmpty, "steady light never triggers")
        check(replay([100] + Array(repeating: 20, count: 8) + [100]).isEmpty, "a persistent shadow is rejected")
        check(replay((0..<30).map { 100 - Double($0) }).isEmpty, "gradual dimming is rejected")
        check(replay([0, 0, 0, 0]).isEmpty, "darkness is not a tap")
        check(replay([4, 0.5, 4]).count == 1, "relative detection works at low ambient light")
        check(replay([100, 20, .nan, 100]).isEmpty, "invalid data clears pending contact")
        check(replay([100, 20, -1, 100]).isEmpty, "negative lux clears pending contact")
        check(replay([100, 20, 100], interval: 0.7).isEmpty, "a report gap cannot join stale measurements")
        check(replay([100, 20, 100], resetAt: 2).isEmpty, "wake reset discards a prior pulse")
        check(replay([100, 20, 100, 20, 100], resetAt: 2).count == 1, "fresh post-wake pulse works immediately")
        var detector = PhysicalTapDetector()
        _ = detector.light(100, at: 1)
        check(!detector.light(20, at: 1), "duplicate timestamps are ignored")
        check(!detector.light(20, at: 0.5), "out-of-order timestamps are ignored")
        check(!detector.light(20, at: .nan), "invalid timestamp ignored")
        check(!detector.light(100, at: 1.2), "ignored data cannot manufacture a tap")
        var bytes = [UInt8](repeating: 0, count: 122)
        let bits = Float(12.5).bitPattern
        for index in 0..<4 { bytes[40 + index] = UInt8(truncatingIfNeeded: bits >> (8 * index)) }
        check(bytes.withUnsafeBufferPointer { PhysicalTapReport.lux($0) } == 12.5, "native optical packet decoding")
        check(Array(bytes.dropLast()).withUnsafeBufferPointer { PhysicalTapReport.lux($0) } == nil, "wrong report size rejected")
        var lid = PhysicalTapLidGuard()
        lid.reset(at: 0)
        check(!lid.allowsTap(at: 4), "missing lid readings cannot arm touch detection")
        for index in 0...29 { lid.update(angle: 100, at: Double(index) / 10) }
        check(!lid.allowsTap(at: 2.9), "startup waits three seconds for the lid")
        lid.update(angle: 100.03, at: 3)
        check(lid.allowsTap(at: 3), "stable lid arms after three seconds")
        lid.update(angle: 100.06, at: 3.1)
        check(lid.allowsTap(at: 3.1), "fine-angle sensor noise does not pause detection")
        lid.update(angle: 100.4, at: 3.2)
        lid.update(angle: 100.8, at: 3.3)
        check(!lid.allowsTap(at: 3.3), "cumulative small lid movements trigger settling")
        lid.update(angle: 102, at: 3.4)
        for index in 35...63 { lid.update(angle: 102, at: Double(index) / 10) }
        check(!lid.allowsTap(at: 6.3), "continued adjustment restarts the settling period")
        lid.update(angle: 102, at: 6.5)
        check(lid.allowsTap(at: 6.5), "touch re-arms after the last adjustment settles")
        check(!lid.allowsTap(at: 7.1), "stale lid data blocks touch")
        lid.update(angle: 102, at: 7.2)
        check(!lid.allowsTap(at: 7.2), "recovered lid stream settles before arming")
        lid.update(angle: nil, at: 7.3)
        check(!lid.allowsTap(at: 7.3), "failed lid read immediately blocks touch")
        lid.update(angle: 5, at: 7.4)
        check(!lid.allowsTap(at: 7.4), "nearly closed lid cannot arm")
        lid.update(angle: .nan, at: 7.5)
        check(!lid.allowsTap(at: 7.5), "invalid angle cannot arm")
        lid.reset(at: 8)
        for index in 80...109 { lid.update(angle: 110, at: Double(index) / 10) }
        check(!lid.allowsTap(at: 10.9), "wake resets the settling guard")
        lid.update(angle: 110, at: 11)
        check(lid.allowsTap(at: 11), "stable post-wake lid becomes ready")
        let readyDeadline = lid.blockedUntil
        lid.update(angle: 140, at: 10)
        check(lid.blockedUntil == readyDeadline, "out-of-order lid samples do not alter current state")
        let suite="physical-tap-tests-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        check(NotchPreferences.physicalTapEnabled(in:defaults), "touch works by default without calibration")
        check(NotchPreferences.physicalTapThreshold(in:defaults) == 1.1, "default touch uses the established standard threshold")
        defaults.set(true, forKey: NotchPreferences.physicalTapEnabledKey)
        check(NotchPreferences.physicalTapEnabled(in:defaults), "existing enabled preference works without calibration")
        let profile = PhysicalTapCalibrationProfile(version: 1, date: Date(), sensitivities: ["standard"], baselineLux: 100)
        defaults.set(try! JSONEncoder().encode(profile), forKey: NotchPreferences.physicalTapCalibrationKey)
        check(NotchPreferences.physicalTapEnabled(in:defaults), "validated touch can be enabled")
        defaults.set("gentle", forKey: NotchPreferences.physicalTapSensitivityKey)
        check(NotchPreferences.physicalTapEnabled(in:defaults), "manual sensitivity remains available after calibration")
        check(NotchPreferences.physicalTapThreshold(in:defaults) == 0.7, "manual sensitivity overrides the calibration suggestion")
        defaults.set("standard", forKey: NotchPreferences.physicalTapSensitivityKey)
        defaults.set(false, forKey: NotchPreferences.physicalTapEnabledKey)
        check(!NotchPreferences.physicalTapEnabled(in:defaults), "user can disable calibrated touch")
        defaults.set(Data([0]), forKey: NotchPreferences.physicalTapCalibrationKey)
        check(NotchPreferences.calibration(in:defaults) == nil, "corrupt calibration is discarded")
        check(!NotchPreferences.physicalTapEnabled(in:defaults), "disabled preference survives invalid calibration")
        defaults.set(true, forKey: NotchPreferences.physicalTapEnabledKey)
        check(NotchPreferences.physicalTapEnabled(in:defaults), "invalid calibration cannot disable physical taps")
        defaults.removeObject(forKey: NotchPreferences.physicalTapCalibrationKey)
        check(NotchPreferences.physicalTapEnabled(in:defaults), "removing personal calibration preserves built-in detection")
        check(NotchPreferences.secondPhysicalTap(in:defaults) == .close,"second tap defaults to close")
        for action in PhysicalTapAction.allCases {
            defaults.set(action.rawValue,forKey:NotchPreferences.secondPhysicalTapKey)
            check(NotchPreferences.secondPhysicalTap(in:defaults) == action,"second action persists")
        }
        defaults.set("future-unknown",forKey:NotchPreferences.secondPhysicalTapKey)
        check(NotchPreferences.secondPhysicalTap(in:defaults) == .close,"unknown setting closes instead of executing")


        print("Passed \(checks) light-plus-motion tap, lid guard and preference checks")
    }
}
