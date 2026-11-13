import Foundation

nonisolated struct PhysicalTapSample: Sendable {
    enum Kind: Sendable { case acceleration, rotation, light, lid }
    let kind: Kind
    let time: Double
    let value: SIMD3<Double>
}

/// Raw samples live only for this calibration. Nothing is written to disk or uploaded.
nonisolated final class PhysicalTapCalibrationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [PhysicalTapSample] = []
    private var overflowed = false

    func append(_ sample: PhysicalTapSample) {
        lock.withLock {
            guard samples.count < 120_000 else { overflowed = true; return }
            samples.append(sample)
        }
    }

    func take() -> [PhysicalTapSample]? {
        lock.withLock {
            defer { samples.removeAll(); overflowed = false }
            return overflowed ? nil : samples
        }
    }
}

nonisolated enum PhysicalTapCalibrationEvaluation {
    struct Trial: Sendable {
        enum Kind: Sendable { case quiet, tap, fingerPass }
        let kind: Kind
        let start: Double
        let end: Double
    }

    struct Result: Sendable {
        let profile: PhysicalTapCalibrationProfile?
        let message: String
    }

    static func evaluate(samples: [PhysicalTapSample], trials: [Trial]) -> Result {
        guard let quiet = trials.first, quiet.kind == .quiet, quiet.end - quiet.start >= 4.5,
              trials.filter({ $0.kind == .tap }).count == 5,
              trials.filter({ $0.kind == .fingerPass }).count == 2,
              let end = trials.last?.end,
              zip(trials, trials.dropFirst()).allSatisfy({ $0.end <= $1.start }) else {
            return Result(profile: nil, message: "The calibration was interrupted. Start again when you’re ready.")
        }
        let recording = samples.filter { $0.time >= quiet.start && $0.time <= end }
        for kind in [PhysicalTapSample.Kind.acceleration, .rotation, .light, .lid] {
            let stream = recording.filter { $0.kind == kind }.sorted { $0.time < $1.time }
            let gap = kind == .light ? 0.65 : kind == .lid ? 0.5 : 0.08
            guard let first = stream.first, let last = stream.last,
                  first.time - quiet.start <= gap, end - last.time <= gap,
                  stream.allSatisfy({ $0.value.x.isFinite && $0.value.y.isFinite && $0.value.z.isFinite }),
                  zip(stream, stream.dropFirst()).allSatisfy({ $1.time - $0.time <= gap }) else {
                return Result(profile: nil, message: "A sensor stopped reporting. Keep your Mac awake and try again.")
            }
        }
        let angles = recording.filter { $0.kind == .lid }.map { $0.value.x }
        guard angles.allSatisfy({ (20...180).contains($0) }),
              (angles.max() ?? 0) - (angles.min() ?? 0) < 0.75 else {
            return Result(profile: nil, message: "The lid moved during calibration. Let it settle, then try again.")
        }
        let light = recording.filter { $0.kind == .light }
        let baseline = light.filter { $0.time < quiet.end }.map { $0.value.x }.sorted()
        guard !baseline.isEmpty, baseline[baseline.count / 2] > 0.25,
              light.allSatisfy({ $0.value.x >= 0 }) else {
            return Result(profile: nil, message: "There’s too little light to recognize touch reliably. Try a brighter spot.")
        }
        let baselineLux = baseline[baseline.count / 2]
        let baselineRange = (baseline.last! - baseline.first!) / baselineLux
        guard baselineRange < 0.15 else {
            return Result(profile: nil, message: "The light changed during the quiet baseline. Try again with steady lighting.")
        }
        // A pass must actually shade the sensor; an unobserved control cannot validate rejection.
        for trial in trials where trial.kind == .fingerPass {
            let values = light.filter { $0.time >= trial.start && $0.time < trial.end }.map { $0.value.x }
            guard let minimum = values.min(), let maximum = values.max(), maximum > 0.25,
                  (maximum - minimum) / maximum >= 0.08 else {
                return Result(profile: nil, message: "The sensor didn’t see both finger passes. Move your finger directly across the tap spot, without touching the screen.")
            }
        }
        var validated: [String] = []
        for name in ["gentle", "standard", "firm"] {
            let threshold = NotchPreferences.threshold(for: name)
            // A small relaxation must still reject controls, providing margin around the chosen setting.
            if [threshold, threshold * 0.9].allSatisfy({ sensitivity in
                let hits = detections(samples: recording, sensitivity: sensitivity)
                let taps = trials.filter { $0.kind == .tap }
                return hits.count == taps.count && taps.allSatisfy { trial in
                    hits.filter { $0 >= trial.start && $0 < trial.end }.count == 1
                }
            }) { validated.append(name) }
        }
        guard !validated.isEmpty else {
            return Result(profile: nil, message: "Your taps and finger passes weren’t distinct enough to save new tuning. Try again with your Mac in its usual position and tap directly over the marked spot.")
        }
        return Result(profile: PhysicalTapCalibrationProfile(version: 1, date: Date(),
            sensitivities: validated, baselineLux: baselineLux),
            message: "All five taps were recognized, and the quiet baseline and both finger passes were rejected. Your personalized sensitivity is ready.")
    }

    private static func detections(samples: [PhysicalTapSample], sensitivity: Double) -> [Double] {
        var detector = PhysicalTapDetector(sensitivity: sensitivity)
        var hits: [Double] = []
        // Preserve callback order, including the native sensor timestamps.
        for sample in samples {
            switch sample.kind {
            case .acceleration: detector.accel(sample.value, at: sample.time)
            case .rotation: detector.gyro(sample.value, at: sample.time)
            case .light:
                if detector.light(sample.value.x, at: sample.time) { hits.append(sample.time) }
            case .lid: break
            }
        }
        return hits
    }
}
