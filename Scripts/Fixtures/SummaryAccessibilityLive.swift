// Opt-in live capture from explicitly selected browser documents and the current Claude window.
import AppKit
import ApplicationServices

enum ScreenRelay {
 static var url: URL? { URL(string:"https://sentient-doubletap-relay.sentient-doubletap-relay.workers.dev") }
 static func identity() throws -> String { try String(contentsOfFile:CommandLine.arguments[1] + "/test-identity",encoding:.utf8) }
}
enum Permissions {
 static func hasAccessibility()->Bool {AXIsProcessTrusted()}
 static func requestAccessibility() { }
}
enum ScreenCapture {
 static func summaryImage(displayID:CGDirectDisplayID,windowPID:pid_t? = nil,windowTitle:String? = nil,windowFrame:CGRect? = nil) async throws -> Data { throw Live.Failure.screenshotForbidden }
}
func ax(_ node:AXUIElement,_ name:String)->CFTypeRef? {
 var v:CFTypeRef?;return AXUIElementCopyAttributeValue(node,name as CFString,&v) == .success ? v:nil
}
@main enum Live {
 static func main() async throws {
  var records:[[String:Any]]=[]
  for id in ["com.microsoft.edgemac","com.google.Chrome","com.apple.Safari","com.anthropic.claudefordesktop"] {

   guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:id).first else {throw Failure.missing(id + " app")}
   let root=AXUIElementCreateApplication(app.processIdentifier)
   let windows=ax(root,"AXWindows") as? [AXUIElement] ?? []
   guard let window=windows.first(where:{(ax($0,"AXTitle") as? String ?? "").localizedCaseInsensitiveContains(CommandLine.arguments[2])}) ?? (id.contains("claude") ? windows.first : nil) else {throw Failure.missing(id + " window (count: \(windows.count), AX trusted: \(AXIsProcessTrusted()))")}
   let start=Date()
   let target = SummaryAccessibility.Target(pid:app.processIdentifier,name:app.localizedName ?? id,browser:!id.contains("claude"),window:window)
   let source=try await Task.detached { try SummaryAccessibility.read(target) }.value
   precondition(source.image == nil && source.text.count > 1000 && source.offscreenTextElements > 0)
   let request=try SummarizeInference.request(base:ScreenRelay.url!,source:source,preference:"",identity:ScreenRelay.identity())
   let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
   precondition(body["image"] == nil)
   var updates=0
   let result=try await SummarizeInference.stream(source:source,preference:""){_ in updates+=1}
   records.append(["application":id,"source_bytes":source.text.utf8.count,"offscreen_elements":source.offscreenTextElements,"truncated":source.truncated,"image_in_request":false,"updates":updates,"summary":result,"elapsed_seconds":Date().timeIntervalSince(start)])
   try source.text.write(toFile:CommandLine.arguments[1] + "/source-\(id).txt",atomically:true,encoding:.utf8)
   try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1] + "/live-results.json"))
   print(id,"PASS",source.text.utf8.count,"bytes",source.offscreenTextElements,"offscreen elements",updates,"stream updates")
  }
 }
 enum Failure:Error{case missing(String), screenshotForbidden}
}
