#!/usr/bin/env python3
"""Compile native AX warmup and exercise the real DEBUG wake-fixture guard with inert services.
Never invokes AX, opens a window, queries real login/wake state, or launches the Sentient app.
"""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import uuid
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'

def member(source,signature):
    start=source.index(signature);end=source.index('{',start)+1;depth=1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[start:end]

wake=(APP/'Views/Settings/OvernightWakeRow.swift').read_text()
polish=(APP/'Self Tests - Temp/SidekickPolishLab.swift').read_text()
fixture=r'''
import Foundation
import Observation
import AppKit
import ApplicationServices
@MainActor enum UserDefaults {
    final class Store {
        func string(forKey key:String)->String? { key=="lab.fixture.nonce" ? ProcessInfo.processInfo.environment["FIXTURE_NONCE"] : nil }
    }
    static let standard=Store()
}
@MainActor final class WakeHelperClient {
    enum DaemonHealth {case ready,notSetUp,requiresApproval,unavailable}
    static let shared=WakeHelperClient()
    var refreshes=0,setups=0
    func healthProbe()async->DaemonHealth{refreshes+=1;return .notSetUp}
    func setUp()async->DaemonHealth{setups+=1;return .notSetUp}
}
@MainActor final class PermissionGuide {
    enum Pane{case overnightWake};struct Job{let pane:Pane}
    static let shared=PermissionGuide();var job:Job?
    func close(){}
}
@MainActor enum CompileOnlyAX {
// AX_HELPER
}
// WAKE_SETUP
@main struct Test {
    @MainActor static func main()async {
        let env=ProcessInfo.processInfo.environment
        let root=URL(fileURLWithPath:env["LAB_SIDEKICK_ROOT"]!,isDirectory:true)
        let enabled=OvernightWakeSetup.enableSourceFixture(root:root)
        let setup=OvernightWakeSetup()
        await setup.refresh();await setup.setUp()
        switch env["EXPECT"]! {
        case "valid":
            precondition(enabled && OvernightWakeSetup.sourceFixtureRefreshes==1 && OvernightWakeSetup.sourceFixtureSetups==1)
            precondition(WakeHelperClient.shared.refreshes==0 && WakeHelperClient.shared.setups==0)
        case "invalid":
            precondition(!enabled && OvernightWakeSetup.sourceFixtureRefreshes==0 && OvernightWakeSetup.sourceFixtureSetups==0)
            precondition(WakeHelperClient.shared.refreshes==0 && WakeHelperClient.shared.setups==0)
        case "normal":
            precondition(!enabled && WakeHelperClient.shared.refreshes==1 && WakeHelperClient.shared.setups==1)
        default: fatalError("unknown case")
        }
        print("PASS wake fixture guard: "+env["EXPECT"]!)
    }
}
'''.replace('// AX_HELPER',member(polish,'static func activateOwnAccessibility()')).replace('// WAKE_SETUP',member(wake,'@MainActor @Observable\nfinal class OvernightWakeSetup'))
with tempfile.TemporaryDirectory(prefix='sentient-source-ui-guard-')as directory:
    path=Path(directory);root=path/'sentient-sidekick-app-fixture';root.mkdir()
    nonce=str(uuid.uuid4())
    (root/'.sidekick-app-fixture').write_text('1\n')
    (root/'fixture.json').write_text(json.dumps({'schema':1,'nonce':nonce,'suite':'ai.sentient.sidekick-app.'+nonce}))
    (path/'main.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-D','DEBUG','-parse-as-library',str(path/'main.swift'),'-o',str(path/'check')],check=True)
    base={**os.environ,'SENTIENT_SELFTEST':'sidekickapp','LAB_SIDEKICK_STAGE':'ui-personal-sources','LAB_SIDEKICK_ROOT':str(root),'FIXTURE_NONCE':nonce}
    for expected,changes in [('valid',{}),('invalid',{'FIXTURE_NONCE':str(uuid.uuid4())}),('normal',{'LAB_SIDEKICK_STAGE':'not-source-fixture'})]:
        subprocess.run([str(path/'check')],check=True,env={**base,**changes,'EXPECT':expected})
    (root/'.sidekick-app-fixture').unlink()
    subprocess.run([str(path/'check')],check=True,env={**base,'EXPECT':'invalid'})
