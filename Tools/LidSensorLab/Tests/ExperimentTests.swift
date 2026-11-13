import Foundation
@main struct Tests {
 static func main() {
  let manual=ExperimentPlan(mode:.missedTaps)
  precondition(manual.isManual && manual.recordsMotion && manual.duration.isInfinite)
  precondition(manual.trials.isEmpty && manual.targetTapCount == 3)
  precondition(manual.phase(at:0) == .manual && manual.phase(at:3600) == .manual)
  precondition(manual.trialIndex(at:20) == nil && manual.phase(at:20).cueIndex == nil)
  print("Missed taps: manual start/stop, three requested taps, native motion recording, no automatic cues or time limit verified.")
  let p=ExperimentPlan()
  precondition(p.duration==29)
  precondition(p.phase(at:0) == .quiet(5))
  precondition(p.phase(at:4.99) == .quiet(1))
  for i in 0..<6 {precondition(p.phase(at:p.cueTime(i)) == .tap(i+1))}
  precondition(p.phase(at:5.8) == .wait(seconds:4,next:2))
  precondition(p.phase(at:8.99) == .wait(seconds:1,next:2))
  precondition(p.phase(at:26) == .wait(seconds:3,next:nil))
  precondition(p.phase(at:28.99) == .wait(seconds:1,next:nil))
  precondition(p.phase(at:29) == .done)
  let light = ExperimentPlan(mode: .ambient)
  precondition(light.duration == 101 && light.trials.count == 12 && light.targetTapCount == 4)
  precondition(light.phase(at: 0) == .quiet(5))
  precondition(light.phase(at: 5) == .prepare(1))
  for i in 0..<12 {
   precondition(light.phase(at: light.cueTime(i)) == .action(i+1))
   precondition(light.phase(at: light.quietSeconds + Double(i)*8) == .prepare(i+1))
  }
  precondition(light.phase(at: 9) == .wait(seconds:4,next:2))
  precondition(light.phase(at: 97) == .wait(seconds:4,next:nil))
  precondition(light.phase(at: 101) == .done)
  precondition(light.trials.filter { $0 == .handPass }.count == 2)
  precondition(light.trials.filter { $0 == .hover }.count == 2)
  precondition(light.trials.filter { $0 == .lighting }.count == 2)
  precondition(light.trials.contains(.desk) && light.trials.contains(.typing))
  let tapping = ExperimentPlan(mode: .tapping)
  precondition(tapping.duration == 45 && tapping.targetTapCount == 10 && tapping.recordsMotion)
  precondition(tapping.trials.allSatisfy { $0 == .tap })
  precondition(tapping.phase(at: 0) == .quiet(5))
  for i in 0..<10 {
   precondition(tapping.cueTime(i) == 5 + Double(i)*4)
   precondition(tapping.phase(at: tapping.cueTime(i)) == .tap(i+1))
  }
  precondition(tapping.phase(at: 44.99) == .wait(seconds:1,next:nil))
  precondition(tapping.phase(at: 45) == .done)
  print("Tap-only: 10 cues four seconds apart, simultaneous motion recording, automatic stop at 45 seconds verified.")
  let fusion = ExperimentPlan(mode: .fusion)
  precondition(fusion.duration == 133 && fusion.trials.count == 16 && fusion.targetTapCount == 6)
  precondition(fusion.trials.filter { $0 == .coincidence }.count == 2)
  for i in 0..<16 {
   precondition(fusion.phase(at: fusion.cueTime(i)) == .action(i+1))
   precondition(fusion.phase(at: fusion.cueTime(i)-1) == .prepare(i+1))
  }
  precondition(fusion.phase(at: 133) == .done)
  var packet = [UInt8](repeating: 0, count: 22)
  for (offset, value) in [(6, Int32(-98304)), (10, Int32(65536)), (14, Int32(32768))] {
   for i in 0..<4 { packet[offset+i] = UInt8(truncatingIfNeeded: UInt32(bitPattern: value) >> (8*i)) }
  }
  let motion = MotionFrame.decode(packet,kind:.gyro,sequence:1,time:1.1,arrival:1.2,ticks:3,timestampSource:"device")!
  precondition(motion.vector == SIMD3(-1.5, 1, 0.5))
  precondition(motion.deviceTicks == 3 && motion.rawHex.split(separator:" ").count == 22)
  precondition(MotionFrame.decode(Array(packet.dropLast()),kind:.gyro,sequence:1,time:0,arrival:0,ticks:0,timestampSource:"device") == nil)
  print("Fusion: 16 trials, six taps, coincidence controls, timing and signed motion packet decoding verified.")
  var bytes = [UInt8](repeating:0,count:122)
  func put(_ offset:Int,_ bits:UInt32) { for i in 0..<4 {bytes[offset+i] = UInt8(truncatingIfNeeded: bits >> (8*i))} }
  put(40,Float(123.25).bitPattern)
  for (i,v) in [UInt32(11),22,33,44].enumerated() {put(20+4*i,v)}
  let frame = ALSFrame.decode(bytes,sequence:7,time:1.2,arrival:1.21,ticks:99,timestampSource:"device")!
  precondition(frame.lux == 123.25 && frame.channels == [11,22,33,44])
  precondition(frame.sequence == 7 && frame.deviceTicks == 99 && frame.time == 1.2 && frame.arrivalTime == 1.21)
  precondition(frame.rawHex.split(separator:" ").count == 122)
  precondition(ALSFrame.decode(Array(bytes.dropLast()),sequence:8,time:0,arrival:0,ticks:0,timestampSource:"device") == nil)
  put(40,Float.nan.bitPattern)
  precondition(ALSFrame.decode(bytes,sequence:9,time:0,arrival:0,ticks:0,timestampSource:"device")?.lux == nil)
  print("Ambient experiment: 12 labelled trials, control coverage, cue timing, auto-stop, native packet decoding and invalid data verified.")
  print("Guided experiment: 5-second baseline, six cues at 4-second intervals, auto-stop at 29 seconds verified.")
 }
}
