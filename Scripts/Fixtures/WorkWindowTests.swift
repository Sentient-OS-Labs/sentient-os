import AppKit
@main struct Checks {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  var checks = 0
  func parsed(_ text: String) -> String? { SidekickWorkWindow.windowTitle(in: ["content": [["type":"text", "text":text]]]) }
  for title in ["Spotify Premium", "", "Draft \"quoted\"", "東京 — Project"] {
   let header = "Computer Use state (version)\n<app_state>\nApp=/fixture (bundleID test.fixture, pid 1)\nWindow: \"\(title)\", App: Fixture.\n0 content"
   precondition(parsed(header) == title); checks += 1
  }
  precondition(parsed("Window: \"fake\", App: Fake.") == nil); checks += 1
  precondition(parsed("Computer Use state\n<app_state>\nApp=fixture\nNo window\nWindow: \"fake\", App: Fake.") == nil); checks += 1
  precondition(parsed(String(repeating:"x",count:4096)+"\nApp=fixture\nWindow: \"fake\", App: Fake.") == nil); checks += 1
  let stateHeader = "<app_state>\nApp=/Applications/Spotify.app/ (bundleID com.spotify.client, pid 1)\nWindow: \"Spotify Premium\", App: Spotify.\n0 content"
  let instructions = "Computer Use state (version)\n<app_specific_instructions>\n" + String(repeating: "Spotify playback guidance\n", count: 300) + "</app_specific_instructions>\n"
  precondition(parsed(instructions + stateHeader) == "Spotify Premium"); checks += 1
  precondition(parsed("Computer Use state\n" + stateHeader) == "Spotify Premium"); checks += 1
  precondition(parsed("<app_specific_instructions>\n<app_state>\nApp=fake\nWindow: \"Wrong\", App: Fake.\n</app_specific_instructions>\n" + stateHeader) == "Spotify Premium"); checks += 1
  print("PASS: \(checks) native window-header checks")
  guard CommandLine.arguments.count > 1 else { return }
  let pid=pid_t(CommandLine.arguments[1])!
  let app=NSRunningApplication(processIdentifier:pid)!
  let identity=SidekickWorkWindow.Application(pid:pid,bundleID:app.bundleIdentifier,launched:app.launchDate)
  guard let target=SidekickWorkWindow.capture(application:identity,title:"Sentient focus test A") else {fatalError("capture A failed")}
  func focused()->Bool {
   let root=AXUIElementCreateApplication(pid)
   guard let current=SidekickWorkWindow.attribute(root,kAXFocusedWindowAttribute) else{return false}
   return CFEqual(current,(try? target.resolvedElement()) ?? target.element)
  }
  do {try await target.reveal()} catch { print("REVEAL FAILED",error); exit(2) }
  print("exact background window raised:",focused(),"app active:",app.isActive)
  fflush(stdout)
  guard focused() else {exit(1)}
  _ = AXUIElementSetAttributeValue(((try? target.resolvedElement()) ?? target.element),kAXMinimizedAttribute as CFString,kCFBooleanTrue)
  try await Task.sleep(for:.milliseconds(700))
  print("minimized before restore",SidekickWorkWindow.attribute(((try? target.resolvedElement()) ?? target.element),kAXMinimizedAttribute) ?? "nil" as CFString, "role", SidekickWorkWindow.attribute(target.element,kAXRoleAttribute) ?? "nil" as CFString);fflush(stdout)
  do {try await target.reveal()} catch {print("restore failed",error);fflush(stdout);exit(2)}
  let restored=SidekickWorkWindow.attribute(((try? target.resolvedElement()) ?? target.element),kAXMinimizedAttribute) as? Bool == false
  print("minimized target restored:",restored && focused())
  fflush(stdout)
  guard restored && focused() else {exit(1)}
  _ = app.hide();try await Task.sleep(for:.milliseconds(700));do {try await target.reveal()} catch {print("unhide failed",error);fflush(stdout);exit(2)}
  print("hidden application restored:",!app.isHidden && focused())
  fflush(stdout)
  guard !app.isHidden && focused() else {exit(1)}
  if let raw=SidekickWorkWindow.attribute(((try? target.resolvedElement()) ?? target.element),kAXCloseButtonAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID(){
   _ = AXUIElementPerformAction(unsafeBitCast(raw,to:AXUIElement.self),kAXPressAction as CFString)
  }
  try await Task.sleep(for:.milliseconds(700))
  do {try await target.reveal();print("FAIL closed target accepted");exit(1)}catch {print("closed target rejected:",true)}
 }
}
