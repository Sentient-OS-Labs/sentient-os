#!/usr/bin/env python3
"""Production termination, idle-update guard and draft handoff with isolated inert peers."""
from pathlib import Path
import os
import subprocess
import tempfile
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'

def member(source,signature):
 start=source.index(signature);end=source.index('{',start)+1;depth=1
 while depth:
  depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[start:end]

delegate=(APP/'App/Sentient_OS_macOSApp.swift').read_text()
updates=(APP/'Updates/UpdateController.swift').read_text()
safe=(APP/'System/SafeAppRelaunch.swift').read_text()
SUPPORT=r'''
import Foundation
@MainActor final class NSApplication {
    enum TerminateReply:Equatable {case terminateLater,terminateNow}
    var replies:[Bool]=[]
    func reply(toApplicationShouldTerminate value:Bool) {replies.append(value)}
    var windows:[Window]=[]
}
struct Window {struct ID {let rawValue:String};var identifier:ID?;var isVisible=false;var isMiniaturized=false}
@MainActor let NSApp=NSApplication()
@MainActor final class MainNavigation {
    static let shared=MainNavigation();var approved=true
    func confirmLeavingKnowledge(_ completion:(Bool)->Void) {completion(approved)}
}
@MainActor final class NativePermissionCheck {
    static let shared=NativePermissionCheck();var hold=false;var closes=0
    func close() async {closes+=1;while hold {try? await Task.sleep(for:.milliseconds(5))}}
}
@MainActor final class SafeAppRelaunch {
    static let shared=SafeAppRelaunch();var approves=true;var cancels=0;var approvals=0;var allowsAutomaticRelaunch=true
    func approveTermination()->Bool {approvals+=1;return approves}
    func cancelPendingRelaunch() {cancels+=1}
}
@MainActor final class VaultActivity {static let shared=VaultActivity();var editorBusy=false}
@MainActor enum UserPresence {static var isAwayFromApp=true}
@MainActor final class ComputerUseGate {static let shared=ComputerUseGate();var isPresenting=false}
enum PersonalSetupView {static let windowID="personal-setup"}
enum UpdateNotice {static var recorded=0;static func recordSilentRelaunch() {recorded+=1}}
func Log(_ value:String) {}
extension URL {static var sentientSupport:URL {URL(fileURLWithPath:ProcessInfo.processInfo.environment["TEST_HANDOFF_ROOT"]!)}}
enum SidekickConversationEvent {struct ReplyReference:Codable,Equatable {let messageID:String}}
'''
source=SUPPORT+'\n@MainActor final class Delegate {\nprivate var isResolvingTermination=false\n'+member(delegate,'func applicationShouldTerminate(')+'\n}\n'
source+='''@MainActor final class UpdateFixture {
 static let appUpdatesEnabled=true
 var pendingInstallHandler:(()->Void)?
 var idleTimer:Timer?
 var preparingIdleInstall=false
'''+member(updates,'private func installIfSafe(')+'\n'+member(updates,'private var isSafeToRelaunch:')+'''
 func trigger() {installIfSafe()}
 var canInstall:Bool {isSafeToRelaunch}
}
'''
source+=member(safe,'enum PermissionRelaunchDraft')
TESTS=r'''
@main enum Tests {
    @MainActor static func main() async throws {
        var count=0
        func check(_ value:Bool,_ label:String) {precondition(value,label);count+=1}
        func settle() async {try? await Task.sleep(for:.milliseconds(30))}
        let delegate=Delegate(),app=NSApplication(),probe=NativePermissionCheck.shared,relaunch=SafeAppRelaunch.shared
        MainNavigation.shared.approved=false
        check(delegate.applicationShouldTerminate(app) == .terminateLater,"Leave decision always returns asynchronously")
        await settle()
        check(app.replies == [false] && probe.closes == 0 && relaunch.cancels == 1,"Declined Knowledge guard cancels restart before any drain or quit")
        MainNavigation.shared.approved=true;probe.hold=true
        _=delegate.applicationShouldTerminate(app)
        _=delegate.applicationShouldTerminate(app)
        await settle()
        check(probe.closes == 1 && app.replies == [false],"Repeated Quit shares a single owned-client drain")
        probe.hold=false;await settle()
        check(app.replies == [false,true] && relaunch.approvals == 1,"Final quit approval follows completed drain")
        relaunch.approves=false;_=delegate.applicationShouldTerminate(app);await settle()
        check(app.replies.last == false,"Late restart preparation failure keeps current app open")
        relaunch.approves=true
        let update=UpdateFixture();var installs=0
        update.pendingInstallHandler={installs+=1}
        check(update.canInstall,"Idle baseline can install")
        relaunch.allowsAutomaticRelaunch=false
        check(!update.canInstall,"Shared busy policy blocks tasks, installations and active proof")
        relaunch.allowsAutomaticRelaunch=true
        for window in [Window(identifier:.init(rawValue:"personal-setup-AppWindow-1"),isVisible:true),
                       Window(identifier:.init(rawValue:"personal-setup"),isMiniaturized:true)] {
            NSApp.windows=[window];check(!update.canInstall,"Active or minimized personal setup is preserved")
        }
        NSApp.windows=[];ComputerUseGate.shared.isPresenting=true
        check(!update.canInstall,"Permission repair UI is preserved")
        ComputerUseGate.shared.isPresenting=false;VaultActivity.shared.editorBusy=true
        check(!update.canInstall,"Unsaved Knowledge edits defer updates")
        VaultActivity.shared.editorBusy=false;UserPresence.isAwayFromApp=false
        check(!update.canInstall,"Foreground interaction defers silent update")
        UserPresence.isAwayFromApp=true;probe.hold=true;update.trigger();await settle()
        relaunch.allowsAutomaticRelaunch=false;probe.hold=false;await settle()
        check(installs == 0 && update.pendingInstallHandler != nil,"Work begun during drain preserves pending update")
        relaunch.allowsAutomaticRelaunch=true;update.trigger();await settle()
        check(installs == 1 && UpdateNotice.recorded == 1,"Idle update installs exactly once after recheck")
        let generation=UUID(),reply=SidekickConversationEvent.ReplyReference(messageID:"synthetic-reply")
        try PermissionRelaunchDraft.save(.init(text:"unsent synthetic",reply:reply,generation:generation))
        let file=URL.sentientSupport.appendingPathComponent("Sidekick/PermissionRelaunchDraft.json")
        let mode=(try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as! NSNumber).intValue
        check(mode == 0o600,"Draft handoff file is private")
        let first=PermissionRelaunchDraft.take(),second=PermissionRelaunchDraft.take()
        check(first?.text == "unsent synthetic" && second?.generation == generation && second?.reply == reply,
              "Read or generation-mismatch inspection never consumes unsent draft")
        PermissionRelaunchDraft.clear()
        check(PermissionRelaunchDraft.take() == nil,"Successful restore can explicitly consume handoff")
        try PermissionRelaunchDraft.save(.init(text:"",reply:reply,generation:generation))
        check(PermissionRelaunchDraft.take()?.reply == reply,"Reply-only composer survives relaunch")
        try PermissionRelaunchDraft.save(.init(text:"",reply:nil,generation:generation))
        check(PermissionRelaunchDraft.take() == nil,"Empty composer clears obsolete handoff")
        print("PASS \(count) termination, idle-update and private-draft checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-safe-relaunch-') as directory:
 root=Path(directory)
 (root/'Test.swift').write_text(source+'\n'+TESTS)
 binary=root/'test'
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'Test.swift'),'-o',str(binary)],check=True,timeout=60)
 subprocess.run([str(binary)],env=dict(os.environ,TEST_HANDOFF_ROOT=str(root/'app-support')),check=True,timeout=15)
