// Conservative discovery hint, separate from light-confirmed activation and rapid tapping.
// This only recognizes a repeated motion motif; the owner may show a hover preview, never open input.
import Foundation

nonisolated struct PhysicalMissedTapDetector {
    private var gyroBase: SIMD3<Double>?
    private var accelBase: SIMD3<Double>?
    private var gyroTime = -Double.infinity
    private var accelTime = -Double.infinity
    private var accelHigh = SIMD3<Double>.zero
    private var noise = 0.12
    private var impactEnergy = 0.0
    private var impactPeak = 0.0
    private var impactValley = 0.0
    private var previousImpact = 0.0
    private var impactArmed = true
    private var candidate: Pulse?
    private var sequence: [Signature] = []
    private var strongSequence: [Signature] = []
    private struct Pulse {
        let start: Double
        var peak: Double
        var axis: SIMD3<Double>
        var opposite = 0.0
        var gyroEnergy = SIMD3<Double>.zero
        var accelEnergy = SIMD3<Double>.zero
        var onsetAccelEnergy = SIMD3<Double>.zero
        var accelPeak = 0.0
        var tailEnergy = 0.0
        var tailSamples = 0
    }
    private struct Signature {
        let time: Double
        let axis: SIMD3<Double>
        let peak: Double
    }
    /// Hint-only typing guard: include key release/ring-down and a held key.
    static func keyboardActive(downAge: Double, upAge: Double, modifierAge: Double, keyHeld: Bool = false) -> Bool {
        guard downAge.isFinite, upAge.isFinite, modifierAge.isFinite,
              downAge >= 0, upAge >= 0, modifierAge >= 0 else { return true }
        return keyHeld || min(downAge, upAge, modifierAge) < 1
    }
    mutating func clearSequence() { candidate = nil; sequence.removeAll(keepingCapacity:true); strongSequence.removeAll(keepingCapacity:true) }
    mutating func reset() { self = Self() }
    mutating func accel(_ value: SIMD3<Double>, at time: Double) {
        guard valid(value), time.isFinite, time > accelTime else { return }
        let dt = time-accelTime; accelTime = time
        guard dt < 0.08, let base = accelBase else { accelBase=value;accelHigh = .zero;clearSequence();return }
        accelHigh=value-base;accelBase=base+accelHigh*(1-exp(-dt/0.012))
        if var pulse=candidate {
            pulse.accelEnergy += accelHigh*accelHigh
            if time-pulse.start <= 0.025 {pulse.onsetAccelEnergy += accelHigh*accelHigh}
            pulse.accelPeak=max(pulse.accelPeak,length(accelHigh))
            candidate=pulse
        }
    }
    mutating func rotation(_ value: SIMD3<Double>, at time: Double, inputActive: Bool) -> Bool {
        guard valid(value), time.isFinite, time > gyroTime else { return false }
        let dt=time-gyroTime;gyroTime=time
        guard dt < 0.08, let base=gyroBase else { gyroBase=value;clearSequence();return false }
        let high=value-base;gyroBase=base+high*(1-exp(-dt/0.012))
        let magnitude=length(high)
        let power=magnitude*magnitude
        impactEnergy += (power-impactEnergy)*(1-exp(-dt/(power>impactEnergy ? 0.002:0.022)))
        let envelope=sqrt(max(0,impactEnergy))
        impactPeak=max(impactPeak,envelope)
        if !impactArmed && envelope<max(noise*1.5,impactPeak*0.4) {
            impactArmed=true;impactValley=envelope
        }
        if impactArmed {impactValley=min(impactValley,envelope)}
        let freshAttack=impactArmed && envelope>previousImpact*1.025 && envelope>impactValley*1.8
        previousImpact=envelope
        guard !inputActive, time-accelTime < 0.05 else {clearSequence();return false}
        // A discovery attempt can be deliberate: three contacts across six seconds.
        sequence.removeAll {time-$0.time > 6.5}
        strongSequence.removeAll {time-$0.time > 6.5}
        if var pulse=candidate {
            if magnitude>pulse.peak {pulse.peak=magnitude;pulse.axis=high/max(magnitude,1e-12)}
            pulse.opposite=max(pulse.opposite,-dot(high,pulse.axis))
            pulse.gyroEnergy += high*high
            if time-pulse.start >= 0.065 {pulse.tailEnergy += magnitude*magnitude;pulse.tailSamples += 1}
            if time-pulse.start < 0.13 {candidate=pulse;return false}
            candidate=nil
            let gyroTotal=sum(pulse.gyroEnergy),accelTotal=sum(pulse.accelEnergy)
            guard gyroTotal>0, accelTotal>0 else {return false}
            let verticalFraction=pulse.accelEnergy.z/accelTotal
            let onsetVertical=pulse.onsetAccelEnergy.z/max(1e-12,sum(pulse.onsetAccelEnergy))
            let yawFraction=pulse.gyroEnergy.z/gyroTotal
            let tail=sqrt(pulse.tailEnergy/Double(max(1,pulse.tailSamples)))/pulse.peak
            let reversing=pulse.opposite/pulse.peak
            let ordinary=pulse.peak>=0.8 && pulse.accelPeak>=0.003 && pulse.accelPeak<0.5
                && reversing>=0.4 && tail<0.55 && yawFraction<0.08
                && (verticalFraction>0.60 || onsetVertical>0.70)
            // Three stronger impacts provide more evidence: permit lap tilt, direction
            // variation and longer ringing, but still require vertical, reversing motion.
            let strong=pulse.peak>=3 && pulse.accelPeak>=0.04 && pulse.accelPeak<1
                && reversing>=0.25 && tail<0.85 && yawFraction<0.18 && verticalFraction>0.60
            let signature=Signature(time:pulse.start,axis:pulse.axis,peak:pulse.peak)
            // The first impact establishes a predominantly vertical contact. Later
            // contacts can land during lid wobble: corroborate their fresh reversing
            // rotation against that established direction, without requiring the same
            // acceleration-energy distribution on every strike.
            let followsContact = sequence.last.map { last in
                pulse.start-last.time <= 3 && pulse.start-last.time >= 0.16
                    && abs(dot(signature.axis,last.axis))>=0.90
                    && (0.25...4.0).contains(signature.peak/last.peak)
            } ?? false
            let overlapping = followsContact && pulse.peak>=0.8 && pulse.accelPeak>=0.003
                && pulse.accelPeak<0.5 && reversing>=0.30 && tail<0.60 && yawFraction<0.25
            let normalMatch=(ordinary || overlapping) && Self.append(signature,to:&sequence,alignment:0.90,strength:0.25...4.0)
            let strongMatch=strong && Self.append(signature,to:&strongSequence,alignment:0.80,strength:0.2...5)
            if normalMatch || strongMatch {
                sequence.removeAll(keepingCapacity:true);strongSequence.removeAll(keepingCapacity:true)
                return true
            }
        } else if freshAttack && magnitude>=max(0.8,noise*5) {
            impactArmed=false;impactPeak=envelope
            candidate=Pulse(start:time,peak:magnitude,axis:high/max(magnitude,1e-12),
                gyroEnergy:high*high,accelEnergy:accelHigh*accelHigh,onsetAccelEnergy:accelHigh*accelHigh,accelPeak:length(accelHigh))
        } else {
            noise += (min(magnitude,noise*2+0.02)-noise)*min(1,dt/2)
        }
        return false
    }
    private static func append(_ signature:Signature,to sequence:inout [Signature],alignment:Double,strength:ClosedRange<Double>)->Bool {
        if let last=sequence.last {
            let gap=signature.time-last.time
            if gap<0.16 {return false} // Ignore residual vibration rather than resetting progress.
            if gap>3 || abs(signature.axis.x*last.axis.x + signature.axis.y*last.axis.y + signature.axis.z*last.axis.z)<alignment
                || !strength.contains(signature.peak/last.peak) {sequence.removeAll(keepingCapacity:true)}
        }
        sequence.append(signature)
        return sequence.count>=3
    }
    private func sum(_ v:SIMD3<Double>)->Double {v.x+v.y+v.z}
    private func dot(_ a:SIMD3<Double>,_ b:SIMD3<Double>)->Double {sum(a*b)}
    private func length(_ v:SIMD3<Double>)->Double {sqrt(dot(v,v))}
    private func valid(_ v:SIMD3<Double>)->Bool {v.x.isFinite && v.y.isFinite && v.z.isFinite}
}
