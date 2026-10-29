#!/usr/bin/env python3
"""Run hosted declarations and optional native diagnostics against protocol fixtures.
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
    func data(forKey k:String)->Data?{values[k] as? Data}
    func removeObject(forKey k:String){values.removeValue(forKey:k)}
}
enum CodexRuntime { static var accountIdentity:String?="synthetic-account"; static let sessionScope="fixture" }
enum Analytics { static func signal(_ name:String,parameters:[String:String]){} }
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
    static var records:[DetectedConnector] {
        get { cached(for:.chatgpt)+cached(for:.claude) }
        set {
            for origin in [DetectedConnector.Origin.chatgpt,.claude] {
                if let key=storageKey(for:origin) {
                    UserDefaults.standard.set(try! JSONEncoder().encode(newValue.filter{$0.origin==origin}),forKey:key)
                }
            }
        }
    }
    static func logicalServices(_ values:[DetectedConnector])->[DetectedConnector]{values}
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
fixture=fixture.replace('// CENSUS_METHODS','\n'.join(member(census,s)for s in('static func verifyConnection(','static func readinessAccountIdentity(','static func isReady(','static func recordReadOutcome(','static func confirmSelection(','static func preservingReadiness(','static func persist(','static func cached(','private static func storageKey(')))
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
        for backend in [ModelBackend.chatgpt,.claude] {
            clear();ModelBackend.current=backend
            MailProbeProcess.state.withLock{$0.invalid=true;$0.blocked=true}
            for slug in ["gmail","google-calendar","google-drive"] {
                check(HostedConnectorSetup.confirm(slug:slug),"Done immediately selects \(backend.rawValue)/\(slug) despite unavailable metadata")
            }
            check(ConnectorCensus.records.count==3 && ConnectorCensus.records.allSatisfy{$0.canAttempt && !$0.isReady},
                  "declarations permit first reads without fabricating verified OAuth")
            check(UserDefaults.standard.bool(forKey:"dbg.run.gmail") && UserDefaults.standard.bool(forKey:"dbg.run.calendar")
                && UserDefaults.standard.bool(forKey:"mcp.google-drive.kb"),"all source opt-ins are saved")
            check(MailProbeProcess.state.withLock{$0.started}==0 && MailAccountCollection.calls==0,
                  "Done launches no metadata probe, model turn or contact collection")
            let origin=ConnectorCensus.DetectedConnector.Origin(backend:backend)!
            ConnectorCensus.persist([],for:origin)
            check(ConnectorCensus.records.count==3 && ConnectorCensus.records.allSatisfy(\.canAttempt),
                  "empty catalog refresh cannot erase explicit selections for \(backend.rawValue)")
            let metadata=ConnectorCensus.records.map { record in
                ConnectorCensus.DetectedConnector(slug:record.slug,displayName:record.displayName,origin:origin,
                    serverURL:backend == .claude ? ConnectorRegistry.pack(forSlug:record.slug)?.claudeServerURL:nil,
                    catalogID:backend == .chatgpt ? ConnectorRegistry.pack(forSlug:record.slug)?.codexCatalogID:nil,
                    iconPath:nil,healthy:false,lastSeen:.now)
            }
            ConnectorCensus.persist(metadata,for:origin)
            check(ConnectorCensus.records.allSatisfy{$0.canAttempt && !$0.isReady},
                  "catalog refresh retains current-provider declarations despite stale health for \(backend.rawValue)")
            HostedConnectorSetup.settingsOpened(slug:"gmail")
            check(ConnectorCensus.records.first{$0.slug=="gmail"}!.canAttempt && UserDefaults.standard.bool(forKey:"dbg.run.gmail"),
                  "opening connector settings cannot disable an already selected source")
            ConnectorCensus.recordReadOutcome(slug:"gmail",backend:backend,connected:false)
            check(!ConnectorCensus.records.first{$0.slug=="gmail"}!.canAttempt,"real authentication failure stops later reads")
            check(HostedConnectorSetup.confirm(slug:"gmail",reconnected:true),"explicit reconnect permits retry after authentication failure")
            check(ConnectorCensus.records.first{$0.slug=="gmail"}!.canAttempt && !ConnectorCensus.records.first{$0.slug=="gmail"}!.isReady,
                  "reconnect clears failed health without inventing verified OAuth")
            ConnectorCensus.recordReadOutcome(slug:"gmail",backend:backend,connected:true)
            check(ConnectorCensus.records.first{$0.slug=="gmail"}!.isReady,"successful actual read establishes verified health")
        }
        // Metadata diagnostics remain strict, but never select a source or gate explicit Done.
        for flag in ["link","tool","service","malformed"]{
            clear();MailProbeProcess.state.withLock{f in
                f.missingLink=flag=="link";f.wrongTool=flag=="tool";f.wrongService=flag=="service";f.invalid=flag=="malformed"
            }
            check(!(await ConnectorCensus.verifyConnection(slug:"gmail",backend:.chatgpt)),"diagnostics reject invalid "+flag+" evidence")
            check(!UserDefaults.standard.bool(forKey:"dbg.run.gmail"),"diagnostics never imply reading consent")
            let before=MailProbeProcess.state.withLock{$0.started}
            check(HostedConnectorSetup.confirm(slug:"gmail"),"Done still works after a failed optional diagnostic")
            check(MailProbeProcess.state.withLock{$0.started}==before,"Done does not retry the failing diagnostic")
        }
        clear()
        for slug in ["gmail","google-calendar","google-drive"]{
            check(await ConnectorCensus.verifyConnection(slug:slug,backend:.chatgpt),"live linked read metadata verifies "+slug)
        }
        check(ConnectorCensus.records.filter(\.isReady).count==3,"actual metadata proofs remain independently verified")
        check(!UserDefaults.standard.bool(forKey:"dbg.run.gmail"),"successful diagnostics never opt the user into reading")
        let methods=MailProbeProcess.state.withLock{$0.methods}
        check(Set(methods).isSubset(of:["initialize","initialized","mcpServerStatus/list"]),"Codex diagnostic uses only model-free controls")
        check(!HostedConnectorSetup.confirm(slug:"gmail",backend:.claude),"wrong backend cannot save a source")
        clear();MailProbeProcess.state.withLock{$0.blocked=true}
        let cancelled=Task{await ConnectorCensus.verifyConnection(slug:"gmail",backend:.chatgpt)}
        while MailProbeProcess.state.withLock({$0.started})==0{await Task.yield()}
        cancelled.cancel()
        check(!(await cancelled.value) && ConnectorCensus.records.isEmpty,"cancelled diagnostic cannot persist readiness")
        clear();ModelBackend.current = .claude
        check(await ConnectorCensus.verifyConnection(slug:"gmail",backend:.claude),"Claude diagnostics verify matching connected read metadata")
        check(Set(MailProbeProcess.state.withLock{$0.methods}).isSubset(of:["initialize","mcp_status"]),"Claude diagnostic sends no model prompt")
        let claudeProof=ConnectorCensus.records.first!
        check(claudeProof.readinessAccountIdentity=="claude-a" && claudeProof.isReady,"Claude proof retains its account scope")
        ClaudeAuth.cachedAccountIdentity="claude-b"
        check(!claudeProof.isReady && !claudeProof.canAttempt,"account A proof never authorizes account B")
        check(HostedConnectorSetup.confirm(slug:"gmail"),"account B can explicitly choose its own Gmail")
        let declaredB=ConnectorCensus.records.first!
        check(declaredB.canAttempt && !declaredB.isReady && declaredB.readinessAccountIdentity=="claude-b", "new account declaration replaces old-account proof")
        ClaudeAuth.cachedAccountIdentity="claude-a"
        check(!declaredB.canAttempt,"new account declaration is not inherited on switching back")
        clear();ModelBackend.current = .claude;MailProbeProcess.state.withLock{$0.blocked=true}
        let switched=Task{await ConnectorCensus.verifyConnection(slug:"gmail",backend:.claude)}
        while MailProbeProcess.state.withLock({$0.started})==0{await Task.yield()}
        ClaudeAuth.nativeIdentity="claude-b";MailProbeProcess.state.withLock{$0.blocked=false}
        check(!(await switched.value) && ConnectorCensus.records.isEmpty,"external Claude login during diagnostics cannot save old-account proof")
        clear();ModelBackend.current = .claude;MailProbeProcess.state.withLock{$0.blocked=true}
        let relogin=Task{await ConnectorCensus.verifyConnection(slug:"gmail",backend:.claude)}
        while MailProbeProcess.state.withLock({$0.started})==0{await Task.yield()}
        ClaudeAuth.beginAccountChange();MailProbeProcess.state.withLock{$0.blocked=false}
        check(!(await relogin.value) && ConnectorCensus.records.isEmpty,"explicit login invalidates an in-flight diagnostic scope")
        let claudeLegacy=ConnectorCensus.DetectedConnector(slug:"gmail",displayName:"Gmail",origin:.claude,serverURL:nil,catalogID:nil,iconPath:nil,healthy:true,lastSeen:.now)
        check(claudeLegacy.canAttempt,"legacy declaration stays bound to the first observed account")
        ClaudeAuth.cachedAccountIdentity="claude-b"
        check(!claudeLegacy.canAttempt,"legacy Claude cache is not inherited by a later account")
        clear();ModelBackend.current = .claude;MailProbeProcess.state.withLock{$0.wrongTool=true}
        check(!(await ConnectorCensus.verifyConnection(slug:"gmail",backend:.claude)),"diagnostics do not certify an unrecognized read tool")
        let old=ConnectorCensus.DetectedConnector(slug:"gmail",displayName:"Gmail",origin:.chatgpt,serverURL:nil,catalogID:nil,iconPath:nil,healthy:true,lastSeen:.now)
        check(!old.isReady && old.canAttempt,"legacy healthy selections can attempt a first analysis without verification")
        let legacyData=try JSONEncoder().encode(old);let decoded=try JSONDecoder().decode(ConnectorCensus.DetectedConnector.self,from:legacyData)
        check(decoded.healthy && decoded.readinessVerified == nil && !decoded.isReady,"legacy cache stays compatible without claiming OAuth proof")
        var verified=old;verified.readinessVerified=true
        check(ConnectorCensus.preservingReadiness(old,previous:verified).isReady,"catalog refresh preserves actual verification")
        for origin in [ConnectorCensus.DetectedConnector.Origin.chatgpt,.claude] {
            let catalog=ConnectorCensus.DetectedConnector(slug:"gmail",displayName:"Gmail",origin:origin,serverURL:nil,catalogID:nil,iconPath:nil,healthy:true,lastSeen:.now)
            let disconnected=ConnectorCensus.DetectedConnector(slug:"gmail",displayName:"Gmail",origin:origin,serverURL:nil,catalogID:nil,iconPath:nil,healthy:false,lastSeen:.now,readinessVerified:false)
            check(!ConnectorCensus.preservingReadiness(catalog,previous:disconnected).canAttempt,"catalog presence cannot undo actual authentication failure for \(origin.rawValue)")
            let staleCatalog=ConnectorCensus.DetectedConnector(slug:"gmail",displayName:"Gmail",origin:origin,serverURL:nil,catalogID:nil,iconPath:nil,healthy:false,lastSeen:.now)
            let declared=ConnectorCensus.DetectedConnector(slug:"gmail",displayName:"Gmail",origin:origin,serverURL:nil,catalogID:nil,iconPath:nil,healthy:true,lastSeen:.now,readinessVerified:false,readinessAccountIdentity:origin == .claude ? "claude-a":nil)
            let refreshed=ConnectorCensus.preservingReadiness(staleCatalog,previous:declared)
            check(refreshed.canAttempt && !refreshed.isReady,"a stale catalog health check cannot re-block explicit Done for \(origin.rawValue)")
        }
        clear();ModelBackend.current = .chatgpt
        HostedConnectorSetup.confirm(slug:"gmail")
        CodexRuntime.accountIdentity="other-account"
        check(ConnectorCensus.cached(for:.chatgpt).isEmpty,"another ChatGPT account cannot inherit a declaration")
        CodexRuntime.accountIdentity="synthetic-account"
        check(ConnectorCensus.cached(for:.chatgpt).first?.canAttempt == true,"returning ChatGPT account retains its declaration")
        print("Hosted declarations and diagnostics: \(checks) checks passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='sentient-hosted-readiness-') as directory:
    path=Path(directory);(path/'main.swift').write_text('\n'.join((fixture,probe,setup,checks)))
    subprocess.run(['xcrun','swiftc','-D','DEBUG','-parse-as-library',str(path/'main.swift'),'-o',str(path/'check')],check=True)
    subprocess.run([str(path/'check')],check=True,timeout=20)
