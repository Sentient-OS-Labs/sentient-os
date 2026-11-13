import AppKit
@main struct Windows {
 @MainActor static func main() {
  let app=NSApplication.shared;app.setActivationPolicy(.regular)
  let a=NSWindow(contentRect:NSRect(x:150,y:220,width:370,height:170),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
  let b=NSWindow(contentRect:NSRect(x:200,y:250,width:370,height:170),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
  for (w,title) in [(a,"Sentient focus test A"),(b,"Sentient focus test B")] {
   w.title=title;w.isReleasedWhenClosed=false
   let text=NSTextField(labelWithString:title);text.frame=NSRect(x:30,y:70,width:300,height:30);w.contentView?.addSubview(text)
   w.makeKeyAndOrderFront(nil)
  }
  app.activate()
  withExtendedLifetime((a,b)){app.run()}
 }
}
