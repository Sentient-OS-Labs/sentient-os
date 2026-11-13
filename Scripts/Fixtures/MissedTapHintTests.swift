import Foundation
@main struct Tests {
 static func replay(pulses:[Double], mode:String="tap", input:(Double)->Bool={_ in false}, reset:Double?=nil, decay:Double=0.025, tilt:Double=0, duration:Double=5, amplitude:Double=5, wobbleAfterFirst:Bool=false, ringDuration:Double=0.2)->[Double] {
  var detector=PhysicalMissedTapDetector();var hits:[Double]=[]
  for i in 0...Int(duration*800) {
   let t=Double(i)/800
   if let reset,abs(t-reset)<0.0001 {detector.reset()}
   let pulse=pulses.reduce(0.0){sum,start in
    let x=t-start
    return sum+(x>=0 && x<ringDuration ? amplitude*sin(x*2 * .pi/0.025)*exp(-x/decay):0)
   }
   let gyro=SIMD3(mode=="desk" ? pulse*0.08:pulse,0,0)
   let contactTilt = wobbleAfterFirst && t>(pulses.first ?? 0)+0.2 ? 1.1:tilt
   let a=mode=="hand" ? SIMD3(pulse*0.01,0,1):SIMD3(pulse*0.01*sin(contactTilt),0,1+pulse*0.01*cos(contactTilt))
   detector.accel(a,at:t)
   if detector.rotation(gyro,at:t,inputActive:input(t)){hits.append(t)}
  }
  return hits
 }
 static func main() {
  precondition(replay(pulses:[1,1.4,1.8]).count==1,"three consistent contacts produce one discovery hint")
  precondition(replay(pulses:[1,1.4]).isEmpty,"one or two bumps cannot hint")
  precondition(replay(pulses:[1,1.4,1.8],mode:"desk").isEmpty,"weak desk knocks rejected")
  precondition(replay(pulses:[1,1.4,1.8],mode:"hand").isEmpty,"lateral handling acceleration rejected")
  precondition(replay(pulses:[1,1.4,1.8],input:{_ in true}).isEmpty,"typing never becomes a hint")
  precondition(replay(pulses:[1,1.4,1.8],input:{(1.5...1.6).contains($0)}).isEmpty,"intervening input breaks the sequence")
  precondition(replay(pulses:[1,1.4,1.8],reset:1.6).isEmpty,"reset cannot reuse past taps")
  precondition(replay(pulses:[0.5,3.7,6.9],duration:8).isEmpty,"separate knocks do not accumulate indefinitely")
  precondition(replay(pulses:[]).isEmpty,"idle remains quiet")
  precondition(replay(pulses:[1,2.4,3.3],decay:0.065,tilt:0.45).count==1,"lap tilt, longer ring-down and natural pauses retain the three-tap motif")
  precondition(replay(pulses:[0.5,2.5,4.5],decay:0.065,tilt:0.45,duration:6).count==1,"relaxed taps two seconds apart remain one attempt")
  precondition(replay(pulses:[0.5,3.2,5.9],duration:7).count==1,"three taps across 5.4 seconds do not require a burst")
  precondition(replay(pulses:[0.5,2.5,4.5],decay:0.10,tilt:0.65,duration:6,amplitude:10).count==1,"three harder lap taps tolerate tilted acceleration and ringing")
  precondition(replay(pulses:[0.5,2.5],decay:0.10,tilt:0.65,duration:6,amplitude:10).isEmpty,"hard impacts still require three matching contacts")
  precondition(replay(pulses:[0.5,2.5,4.5],mode:"hand",duration:6,amplitude:10).isEmpty,"strong hand-rest motion still rejected by direction")
  precondition(replay(pulses:[0.5,2.5,4.5],input:{_ in true},decay:0.10,tilt:0.65,duration:6,amplitude:10).isEmpty,"strong typing cannot bypass the input gate")
  precondition(PhysicalMissedTapDetector.keyboardActive(downAge:0.02,upAge:0.1,modifierAge:10),"current typing blocks hint")
  precondition(PhysicalMissedTapDetector.keyboardActive(downAge:0.8,upAge:0.7,modifierAge:10),"typing pauses and release vibration remain blocked")
  precondition(PhysicalMissedTapDetector.keyboardActive(downAge:8,upAge:10,modifierAge:20,keyHeld:true),"held key blocks hint even without repeat")
  precondition(!PhysicalMissedTapDetector.keyboardActive(downAge:10,upAge:9,modifierAge:20),"idle released keyboard permits a new attempt")
  precondition(PhysicalMissedTapDetector.keyboardActive(downAge:.nan,upAge:10,modifierAge:20),"unknown keyboard activity fails closed")
  precondition(replay(pulses:[1,1.25,1.5],wobbleAfterFirst:true).count==1,"matching desk contacts remain detectable while acceleration tilts during lid wobble")
  precondition(replay(pulses:[1,1.25,1.5],input:{_ in true},wobbleAfterFirst:true).isEmpty,"overlapping impacts never bypass active typing suppression")
  precondition(replay(pulses:[1],decay:0.30,duration:5,amplitude:10,ringDuration:0.8).isEmpty,"one long ringing impact cannot become three hint taps")
  precondition(!PhysicalMissedTapDetector.keyboardActive(downAge:8,upAge:8.00005,modifierAge:20),"near-identical idle event-age counters cannot imply a held key")
  precondition(!PhysicalMissedTapDetector.keyboardActive(downAge:8,upAge:10,modifierAge:20),"event-age ordering alone cannot hold the hint off")
  print("PASS: 26 missed-tap hint behavior checks")
 }
}
