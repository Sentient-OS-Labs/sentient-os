import Foundation
import CoreGraphics
final class RapidWriter: @unchecked Sendable {
 let motion:FileHandle,light:FileHandle,lid:FileHandle,input:FileHandle
 let lock=NSLock()
 var failure:String?
 init(prefix:URL) throws {
  func file(_ suffix:String,_ header:String)throws->FileHandle {
   let url=URL(fileURLWithPath:prefix.path+suffix);try Data((header+"\n").utf8).write(to:url)
   let handle=try FileHandle(forWritingTo:url);try handle.seekToEnd();return handle
  }
  input=try file(".input.csv","seconds,key_age,modifier_age,pointer_age,click_age,scroll_age")
  motion=try file(".motion.csv","seconds,arrival_seconds,kind,x,y,z")
  light=try file(".als.csv","seconds,arrival_seconds,lux")
  lid=try file(".csv","report1_read_seconds,report1_degrees")
 }
 func receive(_ value:LabSnapshot) {
  lock.withLock {
   do {
    if let time=value.samples.last?.time {
     func age(_ type:CGEventType)->Double {CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:type)}
     let pointer=[CGEventType.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged].map(age).min()!
     let click=[CGEventType.leftMouseDown,.rightMouseDown,.otherMouseDown].map(age).min()!
     try input.write(contentsOf:Data("\(time),\(age(.keyDown)),\(age(.flagsChanged)),\(pointer),\(click),\(age(.scrollWheel))\n".utf8))
    }
    try motion.write(contentsOf:Data(value.motionFrames.map { "\($0.time),\($0.arrivalTime),\($0.kind.rawValue),\($0.vector.x),\($0.vector.y),\($0.vector.z)\n" }.joined().utf8))
    try light.write(contentsOf:Data(value.alsFrames.compactMap { f in f.lux.map { "\(f.time),\(f.arrivalTime),\($0)\n" } }.joined().utf8))
    try lid.write(contentsOf:Data(value.samples.compactMap { f in f.coarse.map { "\(f.coarseReadTime),\($0)\n" } }.joined().utf8))
   } catch {failure=error.localizedDescription}
  }
 }
 func close(){try? motion.close();try? light.close();try? lid.close();try? input.close()}
}
@main struct RapidCapture {
 static func main() throws {
  let prefix=URL(fileURLWithPath:CommandLine.arguments[1]);let duration=Double(CommandLine.arguments[2])!
  let writer=try RapidWriter(prefix:prefix);let sensor=LabSensors{writer.receive($0)}
  sensor.setMotionEnabled(true);sensor.start()
  print("RECORDING",prefix.lastPathComponent);fflush(stdout)
  Thread.sleep(forTimeInterval:duration);sensor.stop();writer.close()
  let meta:[String:Any]=["motion_file":prefix.lastPathComponent+".motion.csv","als_file":prefix.lastPathComponent+".als.csv","duration_seconds":duration,"error":writer.failure ?? ""]
  try JSONSerialization.data(withJSONObject:meta,options:.prettyPrinted).write(to:URL(fileURLWithPath:prefix.path+".json"))
  print("SAVED",prefix.path)
 }
}
