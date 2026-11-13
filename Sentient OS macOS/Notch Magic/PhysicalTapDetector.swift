// Every physical tap requires an ambient-light pulse with nearby motion evidence.
import Foundation

nonisolated struct PhysicalTapDetector {
    var sensitivity: Double = 1.1
    private var lastTime = -Double.infinity
    private var lastAcceptedTap = -Double.infinity
    private var history: [(time: Double, lux: Double)] = []
    private var candidate: OpticalPulse?
    private var acceleration = MotionBand()
    private var rotation = MotionBand()
    private var accelerationTime = -Double.infinity
    private var rotationTime = -Double.infinity
    private var accelerationPulse = -Double.infinity
    private var rotationPulse = -Double.infinity
    private var motionEvidence: [Double] = []

    private struct OpticalPulse {
        let start: Double
        let baseline: Double
        var minimum: Double
        var minimumTime: Double
    }

    mutating func reset(at time: Double) {
        self = Self(sensitivity: sensitivity)
    }

    mutating func accel(_ value: SIMD3<Double>, at time: Double) {
        guard valid(value), time.isFinite, time > accelerationTime else { return }
        if time - accelerationTime >= 0.08 {
            clearPendingTap()
            history.removeAll(keepingCapacity: true)
        }
        accelerationTime = time
        if let evidence = acceleration.add(value, at: time),
           evidence.rms >= max(0.0011, evidence.noise * 1.8) * motionScale,
           evidence.cancellation < 0.8 {
            accelerationPulse = time
            rememberMotion(at: time)
        }
    }

    mutating func gyro(_ value: SIMD3<Double>, at time: Double) {
        guard valid(value), time.isFinite, time > rotationTime else { return }
        if time - rotationTime >= 0.08 {
            clearPendingTap()
            history.removeAll(keepingCapacity: true)
        }
        rotationTime = time
        if let evidence = rotation.add(value, at: time),
           evidence.rms >= max(0.145, evidence.noise * 1.5) * motionScale,
           evidence.cancellation < 0.8 {
            rotationPulse = time
            rememberMotion(at: time)
        }
    }

    private var motionScale: Double { min(1.8, max(0.85, sensitivity / 1.1)) }

    private mutating func rememberMotion(at time: Double) {
        guard abs(accelerationPulse - rotationPulse) <= 0.06 else { return }
        motionEvidence.removeAll { time - $0 > 1.5 }
        if time - (motionEvidence.last ?? -.infinity) >= 0.01 { motionEvidence.append(time) }
    }

    private mutating func clearPendingTap() {
        candidate = nil
        motionEvidence.removeAll(keepingCapacity: true)
        accelerationPulse = -.infinity
        rotationPulse = -.infinity
    }

    private func valid(_ value: SIMD3<Double>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    mutating func light(_ lux: Double, at time: Double) -> Bool {
        guard time.isFinite, time > lastTime else { return false }
        let gap = time - lastTime
        lastTime = time
        guard lux.isFinite, lux >= 0 else {
            clearPendingTap()
            history.removeAll(keepingCapacity: true)
            return false
        }
        if gap > 0.65 {
            clearPendingTap()
            history.removeAll(keepingCapacity: true)
        }

        motionEvidence.removeAll { time - $0 > 1.5 }
        guard time - accelerationTime < 0.1, time - rotationTime < 0.1 else {
            clearPendingTap()
            history.removeAll(keepingCapacity: true)
            return false
        }
        if var pulse = candidate {
            if lux < pulse.minimum {
                pulse.minimum = lux
                pulse.minimumTime = time
            }
            if time - pulse.start > 0.9 {
                candidate = nil
                history.removeAll(keepingCapacity: true)
                history.append((time, lux))
                return false
            }
            if lux >= pulse.minimum + (pulse.baseline - pulse.minimum) * 0.6 {
                let corroborated = motionEvidence.contains {
                    $0 >= pulse.start - 0.3 && $0 <= pulse.minimumTime + 0.15
                }
                clearPendingTap()
                remember(lux, at: time)
                guard corroborated, time - lastAcceptedTap >= 0.3 else { return false }
                lastAcceptedTap = time
                return true
            }
            candidate = pulse
            return false
        }

        history.removeAll { time - $0.time > 1 }
        if !history.isEmpty {
            let recent = history.suffix(2)
            let baseline = recent.reduce(0.0) { $0 + $1.lux } / Double(recent.count)
            let scale = min(1.5, max(0.9, sensitivity / 1.1))
            let requiredDrop = max(0.08, baseline * 0.17 * scale)
            if baseline > 0.25 && baseline - lux >= requiredDrop {
                candidate = OpticalPulse(start: time, baseline: baseline, minimum: lux, minimumTime: time)
                return false
            }
        }
        remember(lux, at: time)
        return false
    }

    private mutating func remember(_ lux: Double, at time: Double) {
        history.append((time, lux))
        if history.count > 5 { history.removeFirst(history.count - 5) }
    }
}


// High-pass motion and overlapping energy windows match the previously tested
// corroboration path. Both streams contribute, and only light() emits a tap.
private nonisolated struct MotionBand {
    struct Evidence {
        let rms: Double
        let cancellation: Double
        let noise: Double
    }
    private var baseline: SIMD3<Double>?
    private var previousTime: Double?
    private var windowStart = 0.0
    private var vectorSum = SIMD3<Double>.zero
    private var energy = 0.0
    private var count = 0
    private var previousSum = SIMD3<Double>.zero
    private var previousEnergy = 0.0
    private var previousCount = 0
    private var noiseSamples: [Double] = []
    private var noiseIndex = 0
    private var noise = 0.0
    private var noiseUpdated = 0.0

    mutating func add(_ value: SIMD3<Double>, at time: Double) -> Evidence? {
        guard let before = previousTime, let baseline, time > before, time - before < 0.08 else {
            self = Self()
            self.baseline = value
            previousTime = time
            windowStart = time
            return nil
        }
        let delta = time - before
        let high = value - baseline
        self.baseline = baseline + high * (1 - exp(-delta / 0.012))
        previousTime = time
        vectorSum += high
        energy += high.x * high.x + high.y * high.y + high.z * high.z
        count += 1
        guard time - windowStart >= 0.01 else { return nil }
        let sampleCount = Double(count + previousCount)
        let rms = sqrt((energy + previousEnergy) / max(1, sampleCount))
        let vector = vectorSum + previousSum
        let cancellation = sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
            / max(1e-12, sampleCount * rms)
        previousSum = vectorSum
        previousEnergy = energy
        previousCount = count
        vectorSum = .zero
        energy = 0
        count = 0
        windowStart = time
        if noiseSamples.count < 512 { noiseSamples.append(rms) }
        else {
            noiseSamples[noiseIndex] = rms
            noiseIndex = (noiseIndex + 1) % 512
        }
        if time - noiseUpdated >= 0.25, noiseSamples.count >= 25 {
            noise = noiseSamples.sorted()[noiseSamples.count / 5]
            noiseUpdated = time
        }
        return Evidence(rms: rms, cancellation: cancellation, noise: noise)
    }
}

nonisolated enum PhysicalTapReport {
    static func vector(_ bytes: UnsafeBufferPointer<UInt8>) -> SIMD3<Double>? {
        guard bytes.count == 22 else { return nil }
        func read(_ offset: Int) -> Double {
            let bits = UInt32(bytes[offset]) | UInt32(bytes[offset+1]) << 8
                | UInt32(bytes[offset+2]) << 16 | UInt32(bytes[offset+3]) << 24
            return Double(Int32(bitPattern: bits)) / 65_536
        }
        return SIMD3(read(6), read(10), read(14))
    }

    static func lux(_ bytes: UnsafeBufferPointer<UInt8>) -> Double? {
        guard bytes.count == 122 else { return nil }
        let bits = UInt32(bytes[40]) | UInt32(bytes[41]) << 8
            | UInt32(bytes[42]) << 16 | UInt32(bytes[43]) << 24
        let value = Double(Float(bitPattern: bits))
        return value.isFinite && value >= 0 ? value : nil
    }
}


/// Lid angle only gates optical recognition while the display is being adjusted.
nonisolated struct PhysicalTapLidGuard {
    private(set) var blockedUntil = Double.infinity
    private var referenceAngle: Double?
    private var lastReadingTime = -Double.infinity
    private static let settleDuration = 3.0
    private static let movementThreshold = 0.75

    mutating func reset(at time: Double) {
        referenceAngle = nil
        lastReadingTime = -.infinity
        blockedUntil = time + Self.settleDuration
    }

    mutating func update(angle: Double?, at time: Double) {
        guard time.isFinite, time > lastReadingTime else { return }
        let gap = time - lastReadingTime
        lastReadingTime = time
        guard let angle, angle.isFinite, (20...180).contains(angle) else {
            referenceAngle = nil
            blockedUntil = time + Self.settleDuration
            return
        }
        guard let previous = referenceAngle else {
            referenceAngle = angle
            blockedUntil = time + Self.settleDuration
            return
        }
        if gap > 0.5 || abs(angle - previous) >= Self.movementThreshold {
            referenceAngle = angle
            blockedUntil = time + Self.settleDuration
        }
    }

    func allowsTap(at time: Double) -> Bool {
        time.isFinite && referenceAngle != nil && time >= blockedUntil
            && time - lastReadingTime <= 0.5
    }
}
