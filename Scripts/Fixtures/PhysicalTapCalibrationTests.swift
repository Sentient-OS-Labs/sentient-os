import Foundation

@main struct PhysicalTapCalibrationTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static let tapTimes = [8.0, 14, 20, 26, 32]
    static let passTimes = [40.0, 48]
    static let trials: [PhysicalTapCalibrationEvaluation.Trial] = [
        .init(kind: .quiet, start: 0, end: 5),
        .init(kind: .tap, start: 7, end: 11),
        .init(kind: .tap, start: 13, end: 17),
        .init(kind: .tap, start: 19, end: 23),
        .init(kind: .tap, start: 25, end: 29),
        .init(kind: .tap, start: 31, end: 35),
        .init(kind: .fingerPass, start: 39, end: 44),
        .init(kind: .fingerPass, start: 47, end: 52)
    ]

    static func capture(missedTap: Bool = false, contactOnPass: Bool = false,
                        extraTap: Bool = false) -> [PhysicalTapSample] {
        var samples: [PhysicalTapSample] = []
        let pulses = (missedTap ? Array(tapTimes.dropLast()) : tapTimes)
            + (contactOnPass ? passTimes : []) + (extraTap ? [3.0] : [])
        for index in 0...41_600 {
            let time = Double(index) / 800
            let vibration = pulses.reduce(0.0) { sum, impact in
                let age = time - (impact - 0.05)
                guard age >= 0, age < 0.075 else { return sum }
                return sum + sin(age * 2 * .pi * 90) * exp(-age / 0.025)
            }
            samples.append(.init(kind: .acceleration, time: time, value: SIMD3(vibration * 0.02, 0, 1)))
            samples.append(.init(kind: .rotation, time: time, value: SIMD3(0, vibration * 2, 0)))
            if index % 80 == 0 {
                samples.append(.init(kind: .lid, time: time, value: SIMD3(100, 0, 0)))
            }
            if index % 160 == 0 {
                let occlusions = tapTimes + passTimes + (extraTap ? [3.0] : [])
                let lux = occlusions.contains { abs(time - $0) < 0.01 } ? 20.0 : 100.0
                samples.append(.init(kind: .light, time: time, value: SIMD3(lux, 0, 0)))
            }
        }
        return samples
    }

    static func main() {
        let samples = capture()
        let success = PhysicalTapCalibrationEvaluation.evaluate(samples: samples, trials: trials)
        check(success.profile?.isValid == true, "distinct taps and noncontact passes calibrate successfully")
        check(success.profile?.sensitivities.contains("standard") == true, "calibration retains a tested standard setting")
        check(success.profile?.baselineLux == 100, "quiet baseline is measured")
        check(PhysicalTapCalibrationEvaluation.evaluate(samples: capture(missedTap: true), trials: trials).profile == nil,
              "every prompted tap must be recognized")
        check(PhysicalTapCalibrationEvaluation.evaluate(samples: capture(contactOnPass: true), trials: trials).profile == nil,
              "a finger pass classified as a tap fails calibration")
        check(PhysicalTapCalibrationEvaluation.evaluate(samples: capture(extraTap: true), trials: trials).profile == nil,
              "activation during the quiet baseline fails calibration")
        check(PhysicalTapCalibrationEvaluation.evaluate(samples: samples.filter { $0.kind != .rotation }, trials: trials).profile == nil,
              "missing gyroscope cannot validate optical-only taps")
        check(PhysicalTapCalibrationEvaluation.evaluate(samples: samples.filter { !($0.kind == .light && $0.time > 1 && $0.time < 3) }, trials: trials).profile == nil,
              "a native light stream gap fails calibration")
        let movedLid = samples.map { sample in
            sample.kind == .lid && sample.time > 10
                ? PhysicalTapSample(kind: .lid, time: sample.time, value: SIMD3(102, 0, 0)) : sample
        }
        check(PhysicalTapCalibrationEvaluation.evaluate(samples: movedLid, trials: trials).profile == nil,
              "lid adjustment invalidates the recording")
        let noPass = samples.map { sample in
            sample.kind == .light && sample.time > 36
                ? PhysicalTapSample(kind: .light, time: sample.time, value: SIMD3(100, 0, 0)) : sample
        }
        check(PhysicalTapCalibrationEvaluation.evaluate(samples: noPass, trials: trials).profile == nil,
              "unobserved finger passes cannot count as successful controls")
        check(PhysicalTapCalibrationEvaluation.evaluate(samples: samples, trials: Array(trials.dropLast())).profile == nil,
              "incomplete calibration fails")
        let changedBaseline = samples.map { sample in
            sample.kind == .light && sample.time < 3
                ? PhysicalTapSample(kind: .light, time: sample.time, value: SIMD3(70, 0, 0)) : sample
        }
        check(PhysicalTapCalibrationEvaluation.evaluate(samples: changedBaseline, trials: trials).profile == nil,
              "changing ambient baseline fails calibration")
        print("Passed \(checks) calibration separation and recording integrity checks")
    }
}
