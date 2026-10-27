#!/usr/bin/env python3
"""Run actual hosted verification, census confirmation and setup against native protocol fixtures.
Only the subprocess transport and preferences are inert. No account, model, network or source
content is accessed. Exercises successful metadata, malformed/wrong grants and cancellation.
"""
from pathlib import Path
import subprocess
import tempfile
APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'

def member(source, signature):
    start=source.index(signature); end=source.index('{',start)+1; depth=1
    while depth:
        depth += (source[end]=='{')-(source[end]=='}'); end+=1
    return source[start:end]

census=(APP/'Cloud/ConnectorCensus.swift').read_text()
probe=(APP/'Cloud/HostedConnectorReadinessProbe.swift').read_text()
setup=(APP/'Cloud/HostedConnectorSetup.swift').read_text()
fixture=r'''
import Foundation
nonisolated enum ModelBackend: String, Sendable {
    case chatgpt, claude, custom
    @TaskLocal static var runOverride: Self?
    nonisolated(unsafe) static var current = Self.chatgpt
}
final class UserDefaults {
    static let standard = UserDefaults(); var values:[String:Any]=[:]
    func set(_ v:Any?,forKey k:String){ values[k]=v }
    func bool(forKey k:String)->Bool{values[k] as? Bool ?? false}
    func integer(forKey k:String)->Int{values[k] as? Int ?? 0}
    func string(forKey k:String)->String?{values[k] as? String}
    func removeObject(forKey k:String){values.removeValue(forKey:k)}
}
enum CodexRuntime { static var accountIdentity:String?="synthetic-account" }
enum ClaudeAuth {
    struct ReadinessScope:Equatable,Sendable { let accountIdentity:String;let revision:Int }
    struct Status { let accountIdentity:String? }
    static var nativeIdentity:String?="claude-a",cachedAccountIdentity:String?="claude-a"
    static var legacyConnectorAccountIdentity:String?="claude-a"
    static var revision=0
    static var readinessScope:ReadinessScope?{cachedAccountIdentity.map{.init(accountIdentity:$0,revision:revision)}}
    static func refresh()async->Status{
        if nativeIdentity != cachedAccountIdentity{revision+=1;cachedAccountIdentity=nativeIdentity}
        return .init(accountIdentity:nativeIdentity)
    }
    static func beginAccountChange(){revision+=1;cachedAccountIdentity=nil}
}
enum CodexCLI { static func locateBinary()->String?{"fixture-codex"} }
enum ClaudeCLI { static func locateBinary()->String?{"fixture-claude"}; static var baseEnv:[String:String]{[:]} }
enum ConnectorRegistry {
    struct CuratedConnector:Sendable {
        let slug:String; let displayName:String; let codexCatalogID:String?
        let claudeServerURL:String?; let readTools:[String]?; let codexReadTools:[String]?
    }
    struct Server { var codexCatalogID:String? }
    static let ids=["gmail":"connector_2128aebfecb84f64a069897515042a44", "google-calendar":"connector_947e0d954944416db111db556030eea6", "google-drive":"connector_5f3c8c41a1e54ad7a76272c89e2554fa"]
    static func pack(forSlug s:String)->CuratedConnector? {
        guard ids[s] != nil else{return nil}
        return .init(slug:s,displayName:s,codexCatalogID:ids[s],claudeServerURL:"https://fixture.invalid/"+s,readTools:["read"],codexReadTools:["read"])
    }
    static func server(for s:String)->Server?{.init(codexCatalogID:ids[s])}
    static func canonicalSlug(_ s:String)->String{s}
    static func readGenerationKey(_ s:String,_ o:String)->String{"generation."+s+o}
    static func kbEligible(_ s:String,backend:ModelBackend)->Bool{ids[s] != nil}
    static func setKBEnabled(_ s:String,_ v:Bool){UserDefaults.standard.set(v,forKey:"mcp.\(s).kb")}
    static func isKBEnabled(_ s:String)->Bool{UserDefaults.standard.bool(forKey:"mcp.\(s).kb")}
    static func isValidCodexCatalogID(_ id:String)->Bool{id.range(of:"^(?:connector_|asdk_app_)[0-9a-f]{32}$",options:.regularExpression) != nil}
}
enum ConnectorCensus {
// DETECTED
    static var records:[DetectedConnector]=[]
    static func cached(for origin:DetectedConnector.Origin)->[DetectedConnector]{records.filter{$0.origin==origin}}
    @discardableResult static func persist(_ values:[DetectedConnector],for origin:DetectedConnector.Origin)->[DetectedConnector]{records.removeAll{$0.origin==origin};records+=values;return values}
    static func titleCased(_ s:String)->String{s}
    static func slugify(_ s:String)->String{s.lowercased().replacingOccurrences(of:" ",with:"-")}
// CENSUS_METHODS
}
enum MailAccount { enum Engine:String,Sendable{case chatgpt,claude};enum Provider:String,Sendable{case gmail,outlook} }
enum OutlookMailConnector{static func isMail(_ s:String)->Bool{s=="outlook-mail"}}
@MainActor enum MailAccountCollection {
    enum Outcome{case saved,pending,noConnection,noAddress}
    static var calls=0
    static func collect(engine:MailAccount.Engine,provider:MailAccount.Provider)async throws->Outcome{calls+=1;return .saved}
}
func Log(_ s:String){}
func ErrorLabel(_ e:Error)->String{"fixture"}
nonisolated final class MailProbeProcess:@unchecked Sendable {
    private let lock=NSLock();private var stopped=false
    enum Failure:Error{case cancelled}
    static let state=Fixture()
    final class Fixture:@unchecked Sendable {
        let lock=NSLock();var invalid=false;var missingLink=false;var wrongTool=false;var wrongService=false;var blocked=false
        var started=0;var methods:[String]=[];var lastArguments:[String]=[]
        func withLock<T>(_ work:(Fixture)->T)->T{lock.lock();defer{lock.unlock()};return work(self)}
    }
    func start(binary:String,arguments:[String],extraEnvironment:[String:String])throws{Self.state.withLock{$0.started+=1;$0.lastArguments=arguments}}
    func stop(){lock.lock();stopped=true;lock.unlock()}
    func pause()throws{try checkStopped()}
    func checkStopped()throws{lock.lock();let flag=stopped;lock.unlock();if flag{throw CancellationError()}}
    func send(_ value:[String:Any])throws{try checkStopped();Self.state.withLock{$0.methods.append(value["method"] as? String ?? "send")}}
    func request(_ value:[String:Any],claude:Bool=false)throws->[String:Any]{
        while Self.state.withLock({$0.blocked}){try checkStopped();Thread.sleep(forTimeInterval:0.002)}
        try checkStopped()
        let method=value["method"] as? String ?? value["subtype"] as? String ?? "unknown"
        return Self.state.withLock{f in
            f.methods.append(method)
            if method=="initialize"{return [:]}
            if f.invalid{return ["unexpected":true]}
            if method=="mcp_status"{
                return ["mcpServers":[["status":"connected","config":["url":f.wrongService ? "https://other.invalid":"https://fixture.invalid/gmail","id":f.missingLink ? "":"linked-fixture"],"tools":[["name":f.wrongTool ? "write":"read"]]]]]
            }
            var tools:[String:[String:Any]]=[:]
            for (slug,id) in ConnectorRegistry.ids {
                var meta:[String:Any]=["connector_id":f.wrongService ? "connector_00000000000000000000000000000000":id,"connector_name":slug]
                if !f.missingLink{meta["link_id"]="linked-fixture"}
                tools[slug]=["name":slug+".read","title":f.wrongTool ? "write":"read","_meta":meta]
            }
            return ["data":[["name":"codex_apps","tools":tools]]]
        }
    }
}
'''
fixture=fixture.replace('// DETECTED',member(census,'struct DetectedConnector:'))
fixture=fixture.replace('// CENSUS_METHODS','\n'.join(member(census,s)for s in('static func verifyConnection(','static func readinessAccountIdentity(','static func isReady(','static func invalidateReadiness(','static func recordReadOutcome(','static func confirmSelection(','static func preservingReadiness(')))
checks=r'''
@main struct Test {
    @MainActor static func main()async throws{
        var checks=0
        func check(_ value:Bool,_ label:String){precondition(value,label);checks+=1;print("PASS "+label)}
        func clear(){
            UserDefaults.standard.values=[:];ConnectorCensus.records=[];ModelBackend.current = .chatgpt
            ClaudeAuth.nativeIdentity="claude-a";ClaudeAuth.cachedAccountIdentity="claude-a";ClaudeAuth.legacyConnectorAccountIdentity="claude-a";ClaudeAuth.revision=0
            MailProbeProcess.state.withLock{$0.invalid=false;$0.missingLink=false;$0.wrongTool=false;$0.wrongService=false;$0.blocked=false;$0.started=0;$0.methods=[]}
        }
        clear()
        for slug in ["gmail","google-calendar","google-drive"]{
            ConnectorCensus.confirmSelection(slug:slug)
            check(!HostedConnectorSetup.confirm(slug:slug),"browser declaration alone cannot select "+slug)
        }
        check(ConnectorCensus.records.allSatisfy{!$0.isReady},"three fabricated healthy declarations cannot become verified ready")
        for flag in ["link","tool","service","malformed"]{
            clear();MailProbeProcess.state.withLock{f in
                f.missingLink=flag=="link";f.wrongTool=flag=="tool";f.wrongService=flag=="service";f.invalid=flag=="malformed"
            }
            check(!(await HostedConnectorSetup.verifyAndConfirm(slug:"gmail")),"invalid "+flag+" evidence cannot save source")
            check(!UserDefaults.standard.bool(forKey:"dbg.run.gmail"),"failed verification leaves selection unchanged")
        }
        clear()
        for slug in ["gmail","google-calendar","google-drive"]{
            check(await HostedConnectorSetup.verifyAndConfirm(slug:slug),"live linked read metadata selects "+slug)
        }
        check(ConnectorCensus.records.filter(\.isReady).count==3,"three actual metadata proofs become three ready services")
        check(MailAccountCollection.calls==0,"verification performs no email/contact collection")
        let methods=MailProbeProcess.state.withLock{$0.methods}
        check(Set(methods).isSubset(of:["initialize","initialized","mcpServerStatus/list"]),"Codex verification uses only model-free inventory controls")
        HostedConnectorSetup.settingsOpened(slug:"gmail")
        check(!ConnectorCensus.isReady(slug:"gmail",backend:.chatgpt) && UserDefaults.standard.bool(forKey:"dbg.run.gmail"),"opening reconnect preserves selection but invalidates old proof")
        check(!(await HostedConnectorSetup.verifyAndConfirm(slug:"gmail",backend:.claude)),"wrong backend cannot save a late source")
        clear();MailProbeProcess.state.withLock{$0.blocked=true}
        let cancelled=Task{await HostedConnectorSetup.verifyAndConfirm(slug:"gmail")}
        while MailProbeProcess.state.withLock({$0.started})==0{await Task.yield()}
        cancelled.cancel()
        check(!(await cancelled.value) && ConnectorCensus.records.isEmpty && !UserDefaults.standard.bool(forKey:"dbg.run.gmail"),"cancelled verification saves neither readiness nor source selection")
        clear();MailProbeProcess.state.withLock{$0.blocked=true}
        let reset=Task{await HostedConnectorSetup.verifyAndConfirm(slug:"gmail")}
        while MailProbeProcess.state.withLock({$0.started})==0{await Task.yield()}
        await HostedConnectorSetup.beginTeardown();HostedConnectorSetup.endTeardown()
        check(!(await reset.value) && ConnectorCensus.records.isEmpty,"reset drains verification before late readiness can repopulate state")
        clear();ModelBackend.current = .claude
        check(await HostedConnectorSetup.verifyAndConfirm(slug:"gmail",backend:.claude),"Claude requires connected matching server with a reviewed read tool")
        check(Set(MailProbeProcess.state.withLock{$0.methods}).isSubset(of:["initialize","mcp_status"]),"Claude verification sends control requests only and no user/model prompt")
        let claudeProof=ConnectorCensus.records.first!
        check(claudeProof.readinessAccountIdentity=="claude-a" && claudeProof.isReady,"Claude proof records its verified account scope")
        ClaudeAuth.cachedAccountIdentity="claude-b"
        check(!claudeProof.isReady && !claudeProof.canAttempt(legacyCompleted:true),"account A proof never authorizes account B")
        clear();ModelBackend.current = .claude;MailProbeProcess.state.withLock{$0.blocked=true}
        let switched=Task{await HostedConnectorSetup.verifyAndConfirm(slug:"gmail",backend:.claude)}
        while MailProbeProcess.state.withLock({$0.started})==0{await Task.yield()}
        ClaudeAuth.nativeIdentity="claude-b";MailProbeProcess.state.withLock{$0.blocked=false}
        check(!(await switched.value) && ConnectorCensus.records.isEmpty && !UserDefaults.standard.bool(forKey:"dbg.run.gmail"),"external Claude login during verification cannot save old-account proof")
        clear();ModelBackend.current = .claude;MailProbeProcess.state.withLock{$0.blocked=true}
        let relogin=Task{await HostedConnectorSetup.verifyAndConfirm(slug:"gmail",backend:.claude)}
        while MailProbeProcess.state.withLock({$0.started})==0{await Task.yield()}
        ClaudeAuth.beginAccountChange();MailProbeProcess.state.withLock{$0.blocked=false}
        check(!(await relogin.value) && ConnectorCensus.records.isEmpty,"explicit same-account login invalidates an in-flight proof scope")
        let claudeLegacy=ConnectorCensus.DetectedConnector(slug:"gmail",displayName:"Gmail",origin:.claude,serverURL:nil,catalogID:nil,iconPath:nil,healthy:true,lastSeen:.now)
        check(claudeLegacy.canAttempt(legacyCompleted:true),"legacy selected Claude sources retain first-account reading")
        ClaudeAuth.cachedAccountIdentity="claude-b"
        check(!claudeLegacy.canAttempt(legacyCompleted:true),"legacy Claude cache is not inherited by a later account")
        clear();ModelBackend.current = .claude;MailProbeProcess.state.withLock{$0.wrongTool=true}
        check(!(await HostedConnectorSetup.verifyAndConfirm(slug:"gmail",backend:.claude)),"Claude connected status without reviewed reads cannot count")
        let old=ConnectorCensus.DetectedConnector(slug:"gmail",displayName:"Gmail",origin:.chatgpt,serverURL:nil,catalogID:nil,iconPath:nil,healthy:true,lastSeen:.now)
        check(!old.isReady && old.canAttempt(legacyCompleted:true) && !old.canAttempt(legacyCompleted:false),"legacy healthy selection remains attemptable only for an established completed user")
        let legacyData=try JSONEncoder().encode(old)
        let decoded=try JSONDecoder().decode(ConnectorCensus.DetectedConnector.self,from:legacyData)
        check(decoded.healthy && decoded.readinessVerified == nil && !decoded.isReady,"legacy cache decoding retains unknown evidence without falsely counting it")
        var verified=old;verified.readinessVerified=true
        check(ConnectorCensus.preservingReadiness(old,previous:verified).isReady,"catalog refresh preserves a real verification marker")
        let disconnected=ConnectorCensus.DetectedConnector(slug:"gmail",displayName:"Gmail",origin:.chatgpt,serverURL:nil,catalogID:nil,iconPath:nil,healthy:false,lastSeen:.now,readinessVerified:false)
        check(!ConnectorCensus.preservingReadiness(old,previous:disconnected).healthy,"catalog presence cannot undo an actual authentication failure")
        print("Hosted source readiness: \(checks) checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-hosted-readiness-') as directory:
    path=Path(directory);(path/'main.swift').write_text('\n'.join((fixture,probe,setup,checks)))
    subprocess.run(['xcrun','swiftc','-D','DEBUG','-parse-as-library',str(path/'main.swift'),'-o',str(path/'check')],check=True)
    subprocess.run([str(path/'check')],check=True,timeout=20)
