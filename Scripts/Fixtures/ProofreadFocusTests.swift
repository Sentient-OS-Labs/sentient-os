import AppKit
import ApplicationServices
import WebKit
struct ShortcutActivity: Equatable {
 let keys: UInt32; let clicks: UInt32; let scrolls: UInt32
 static var current: Self { .init(keys:CGEventSource.counterForEventType(.combinedSessionState,eventType:.keyDown),clicks:CGEventSource.counterForEventType(.combinedSessionState,eventType:.leftMouseDown),scrolls:CGEventSource.counterForEventType(.combinedSessionState,eventType:.scrollWheel)) }
}
class Panel:NSPanel { override var canBecomeKey:Bool { true } }
@main struct Probe {
 @MainActor static func main() {
  let app=NSApplication.shared
  Task { @MainActor in
   do { try await run() } catch { print(error) }
   app.terminate(nil)
  }
  app.run()
 }
 @MainActor static func run() async throws {
  let app=NSApplication.shared; app.setActivationPolicy(.regular)
  if CommandLine.arguments[1] == "editor" {
   let w=NSWindow(contentRect:NSRect(x:200,y:200,width:600,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false)
   w.title="Disposable proofread editor";w.isReleasedWhenClosed=false
   let v=NSTextView(frame:NSRect(x:0,y:0,width:600,height:300));v.string="Prefix. teh launch are ready. Suffix.";v.isRichText=false;v.isEditable=true;v.allowsUndo=true
   w.contentView=v;w.makeKeyAndOrderFront(nil);app.activate();w.makeFirstResponder(v);v.setSelectedRange((v.string as NSString).range(of:"teh launch are ready."))
   let menu=NSMenu(); let item=NSMenuItem();let edit=NSMenu(title:"Edit");edit.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c");edit.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v");item.submenu=edit;menu.addItem(item);app.mainMenu=menu
   withExtendedLifetime((w,v)){app.run()};return
  }
  let pid=pid_t(CommandLine.arguments[1])!
  NSRunningApplication(processIdentifier:pid)?.activate()
  try await Task.sleep(for:.milliseconds(400))
  let snap=try await ProofreadSelection.captureByCopy(pid:pid)
  func state(_ label:String) async {
   let root=AXUIElementCreateApplication(pid); var f:CFTypeRef?;AXUIElementCopyAttributeValue(root,kAXFocusedUIElementAttribute as CFString,&f)
   var r:CFTypeRef?;AXUIElementCopyAttributeValue(snap.element,kAXSelectedTextRangeAttribute as CFString,&r)
   print(label,"front",NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,"same focused",f.map{CFEqual($0,snap.element)} ?? false,"range",r ?? "nil" as CFString,"valid",await Task.detached{ProofreadSelection.validate(snap)}.value);fflush(stdout)
  }
  await state("captured")
  let p=Panel(contentRect:NSRect(x:500,y:800,width:500,height:80),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  p.contentView=NSTextView(frame:NSRect(x:0,y:0,width:500,height:80));p.makeKeyAndOrderFront(nil);p.makeFirstResponder(p.contentView)
  try await Task.sleep(for:.milliseconds(300));await state("panel key")
  p.orderOut(nil);p.orderFrontRegardless()
  try await Task.sleep(for:.milliseconds(300));await state("panel released")
  var collapsed=CFRange(location:29,length:0)
  let boxed=AXValueCreate(.cfRange,&collapsed)!
  _ = AXUIElementSetAttributeValue(snap.element,kAXSelectedTextRangeAttribute as CFString,boxed)
  let activity=ShortcutActivity.current
  let restored = await ProofreadSelection.restoreFocus(snap,activity:activity)
  precondition(restored,"lost selection must restore after panel focus")
  let result=await ProofreadSelection.apply("The launch is ready.",to:snap,activity:.current)
  precondition(result == .applied,"restored selection must be replaced")
  let refusesNewer = await ProofreadSelection.apply("Should not replace",to:snap,activity:.current) == .changed
  precondition(refusesNewer,"newer text must survive")
  print("PASS: external editor capture, panel handoff, collapsed selection restoration, exact replacement and newer-edit refusal");p.orderOut(nil)
 }
}
