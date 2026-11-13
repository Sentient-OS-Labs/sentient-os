import Foundation
@main struct TapReplay {
 struct Event { let arrival:Double; let time:Double; let kind:String; let value:SIMD3<Double> }
 static func rows(_ url:URL) throws -> [[String:String]] {
  let lines=try String(contentsOf:url,encoding:.utf8).split(separator:"\n")
  let header=lines[0].split(separator:",").map(String.init)
  return lines.dropFirst().map { line in Dictionary(uniqueKeysWithValues:zip(header,line.split(separator:",",omittingEmptySubsequences:false).map(String.init))) }
 }
 static func main() throws {
  for path in CommandLine.arguments.dropFirst() {
   let url=URL(fileURLWithPath:path)
   let meta=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
   let dir=url.deletingLastPathComponent()
   var events:[Event]=[]
   for row in try rows(dir.appendingPathComponent(meta["motion_file"] as! String)) {
    events.append(Event(arrival:Double(row["arrival_seconds"]!)!,time:Double(row["seconds"]!)!,kind:row["kind"]!,value:SIMD3(Double(row["x"]!)!,Double(row["y"]!)!,Double(row["z"]!)!)))
   }
   for row in try rows(dir.appendingPathComponent(meta["als_file"] as! String)) {
    if let lux=Double(row["lux"]!) { events.append(Event(arrival:Double(row["arrival_seconds"]!)!,time:Double(row["seconds"]!)!,kind:"light",value:SIMD3(lux,0,0))) }
   }
   let inputURL=url.deletingPathExtension().appendingPathExtension("input.csv")
   if FileManager.default.fileExists(atPath:inputURL.path) {
    for row in try rows(inputURL) {
     let t=Double(row["seconds"]!)!
     let age=["key_age","modifier_age","pointer_age","click_age","scroll_age"].compactMap{Double(row[$0] ?? "")}.min() ?? .infinity
     events.append(Event(arrival:t,time:t,kind:"input",value:SIMD3(age,0,0)))
    }
   }
   // Match production's 10 Hz whole-degree lid polling, not 100 repeated cached polls.
   var lidTime = -Double.infinity
   for row in try rows(url.deletingPathExtension().appendingPathExtension("csv")) {
    let t=Double(row["report1_read_seconds"]!)!
    if t-lidTime >= 0.099, let angle=Double(row["report1_degrees"]!) {
     events.append(Event(arrival:t,time:t,kind:"lid",value:SIMD3(angle,0,0))); lidTime=t
    }
   }
   let motionShift = Double(ProcessInfo.processInfo.environment["TAP_REPLAY_MOTION_SHIFT"] ?? "0") ?? 0
   if motionShift != 0 {
    events = events.map { event in
     guard event.kind == "accel" || event.kind == "gyro" else { return event }
     return Event(arrival:event.arrival+motionShift,time:event.time+motionShift,kind:event.kind,value:event.value)
    }.filter { $0.time >= 0 && $0.time <= 45 }
   }
   events.sort { if $0.arrival == $1.arrival { return $0.kind < $1.kind };return $0.arrival < $1.arrival }
   var missed=PhysicalMissedTapDetector();var hints:[Double]=[];var lastInput = -Double.infinity;var hintLidOpen=false
   var detector=PhysicalTapDetector();detector.sensitivity = Double(ProcessInfo.processInfo.environment["TAP_REPLAY_SENSITIVITY"] ?? "1.1") ?? 1.1;detector.reset(at:0);var found:[Double]=[]
   for event in events {
    switch event.kind {
    case "input":lastInput=event.time-event.value.x
    case "lid":
     hintLidOpen=(20...170).contains(event.value.x)
     if !hintLidOpen {missed.clearSequence()}
    case "accel":
     detector.accel(event.value,at:event.time)
     missed.accel(event.value,at:event.time)
    case "gyro":
     detector.gyro(event.value,at:event.time)
     let typingGate = ProcessInfo.processInfo.environment["REPLAY_TYPING_GATE"] == "1" && meta["manual_action"] as? String == "typing"
     if missed.rotation(event.value,at:event.time,inputActive:typingGate || event.time-lastInput<0.18 || !hintLidOpen){hints.append(event.time)}
    default:if detector.light(event.value.x,at:event.time){found.append(event.time);missed.clearSequence()}
    }
   }
   let result:[String:Any] = ["file":url.lastPathComponent,"detections":found,"hover_hints":hints]
   print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)
  }
 }
}
