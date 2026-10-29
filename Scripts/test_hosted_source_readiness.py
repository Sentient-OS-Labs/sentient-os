#!/usr/bin/env python3
"""Run hosted declaration and observed-health contracts against inert preferences.
No subprocess transport is provided: selecting a source must not launch a connection probe.
No account, model, network or source content is accessed.
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
setup=(APP/'Cloud/HostedConnectorSetup.swift').read_text()
fixture=r'''
import Foundation
nonisolated enum ModelBackend: String, Sendable {
    case chatgpt, claude, custom, sentient
    var hasSubscriptionConnectors: Bool { self == .chatgpt || self == .claude }
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
enum DirectMCPStore { static func connection(_ slug:String)->String?{nil} }
enum Analytics { static func signal(_ name:String,parameters:[String:String]){} }
enum ClaudeAuth {
    static var cachedAccountIdentity:String?="claude-a"
}

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

'''
fixture=fixture.replace('// DETECTED',member(census,'struct DetectedConnector:'))
fixture=fixture.replace('// CENSUS_METHODS','\n'.join(member(census,s)for s in('static func readinessAccountIdentity(','static func recordReadOutcome(','static func confirmSelection(','static func preservingReadiness(','static func persist(','static func cached(','private static func storageKey(')))
checks=r'''
@main struct Test {
    @MainActor static func main()async throws{
        var checks=0
        func check(_ value:Bool,_ label:String){precondition(value,label);checks+=1;print("PASS "+label)}
        func clear(){
            UserDefaults.standard.values=[:];ConnectorCensus.records=[];ModelBackend.current = .chatgpt
            ClaudeAuth.cachedAccountIdentity="claude-a";MailAccountCollection.calls=0
        }
        for backend in [ModelBackend.chatgpt,.claude] {
            clear();ModelBackend.current=backend
            for slug in ["gmail","google-calendar","google-drive"] {
                check(HostedConnectorSetup.confirm(slug:slug),"Done immediately selects \(backend.rawValue)/\(slug) without metadata probing")
            }
            check(ConnectorCensus.records.count==3 && ConnectorCensus.records.allSatisfy{$0.canAttempt && $0.readinessVerified != true},
                  "declarations permit first reads without fabricating verified OAuth")
            check(UserDefaults.standard.bool(forKey:"dbg.run.gmail") && UserDefaults.standard.bool(forKey:"dbg.run.calendar")
                && UserDefaults.standard.bool(forKey:"mcp.google-drive.kb"),"all source opt-ins are saved")
            check(MailAccountCollection.calls==0,
                  "Done selects without probe APIs or contact collection")
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
            check(ConnectorCensus.records.allSatisfy{$0.canAttempt && $0.readinessVerified != true},
                  "catalog refresh retains current-provider declarations despite stale health for \(backend.rawValue)")
            HostedConnectorSetup.settingsOpened(slug:"gmail")
            check(ConnectorCensus.records.first{$0.slug=="gmail"}!.canAttempt && UserDefaults.standard.bool(forKey:"dbg.run.gmail"),
                  "opening connector settings cannot disable an already selected source")
            ConnectorCensus.recordReadOutcome(slug:"gmail",backend:backend,connected:false)
            check(ConnectorCensus.records.first{$0.slug=="gmail"}!.canAttempt && ConnectorCensus.records.first{$0.slug=="gmail"}!.readinessVerified == false,
                  "authentication failure records unhealthy evidence without revoking the user's next read")
            check(HostedConnectorSetup.confirm(slug:"gmail",reconnected:true),"explicit reconnect permits retry after authentication failure")
            check(ConnectorCensus.records.first{$0.slug=="gmail"}!.canAttempt && ConnectorCensus.records.first{$0.slug=="gmail"}!.readinessVerified == false,
                  "reconnect clears failed health without inventing verified OAuth")
            ConnectorCensus.recordReadOutcome(slug:"gmail",backend:backend,connected:true)
            check(ConnectorCensus.records.first{$0.slug=="gmail"}!.readinessVerified == true,"successful actual read records its health observation")
        }
        clear()
        check(!HostedConnectorSetup.confirm(slug:"gmail",backend:.claude),"wrong backend cannot save a source")
        ModelBackend.current = .claude
        check(HostedConnectorSetup.confirm(slug:"gmail"),"Claude selection needs no native connection check")
        ConnectorCensus.recordReadOutcome(slug:"gmail",backend:.claude,connected:true)
        let claudeObservation=ConnectorCensus.records.first!
        check(claudeObservation.readinessAccountIdentity=="claude-a" && claudeObservation.healthy && claudeObservation.readinessVerified == true,"Claude read observation retains its account scope")
        ClaudeAuth.cachedAccountIdentity="claude-b"
        check(claudeObservation.readinessAccountIdentity != ClaudeAuth.cachedAccountIdentity && claudeObservation.readinessVerified == true && claudeObservation.canAttempt,"account A observation remains attributed to A without vetoing a selected read")
        check(HostedConnectorSetup.confirm(slug:"gmail"),"account B can explicitly choose its own Gmail")
        let declaredB=ConnectorCensus.records.first!
        check(declaredB.canAttempt && declaredB.readinessVerified == false && declaredB.readinessAccountIdentity=="claude-b", "new account declaration replaces old-account proof")
        ClaudeAuth.cachedAccountIdentity="claude-a"
        check(declaredB.canAttempt && declaredB.readinessVerified == false,"account metadata changes do not veto the user's selection")
        let claudeLegacy=ConnectorCensus.DetectedConnector(slug:"gmail",displayName:"Gmail",origin:.claude,serverURL:nil,catalogID:nil,iconPath:nil,healthy:true,lastSeen:.now)
        check(claudeLegacy.canAttempt,"legacy hosted source remains available to attempt")
        ClaudeAuth.cachedAccountIdentity="claude-b"
        check(claudeLegacy.canAttempt && claudeLegacy.readinessVerified == nil,"legacy account metadata is not an admission gate or verified proof")
        let old=ConnectorCensus.DetectedConnector(slug:"gmail",displayName:"Gmail",origin:.chatgpt,serverURL:nil,catalogID:nil,iconPath:nil,healthy:true,lastSeen:.now)
        check(old.readinessVerified == nil && old.canAttempt,"legacy healthy selections can attempt a first analysis without verification")
        let legacyData=try JSONEncoder().encode(old);let decoded=try JSONDecoder().decode(ConnectorCensus.DetectedConnector.self,from:legacyData)
        check(decoded.healthy && decoded.readinessVerified == nil,"legacy cache stays compatible without claiming OAuth proof")
        var observed=old;observed.readinessVerified=true
        check(ConnectorCensus.preservingReadiness(old,previous:observed).readinessVerified == true,"catalog refresh preserves the successful read observation")
        for origin in [ConnectorCensus.DetectedConnector.Origin.chatgpt,.claude] {
            let catalog=ConnectorCensus.DetectedConnector(slug:"gmail",displayName:"Gmail",origin:origin,serverURL:nil,catalogID:nil,iconPath:nil,healthy:true,lastSeen:.now)
            let disconnected=ConnectorCensus.DetectedConnector(slug:"gmail",displayName:"Gmail",origin:origin,serverURL:nil,catalogID:nil,iconPath:nil,healthy:false,lastSeen:.now,readinessVerified:false)
            let failedHealth=ConnectorCensus.preservingReadiness(catalog,previous:disconnected)
            check(failedHealth.canAttempt && !failedHealth.healthy && failedHealth.readinessVerified == false,
                  "catalog retains observed authentication failure without blocking the next selected read for \(origin.rawValue)")
            let staleCatalog=ConnectorCensus.DetectedConnector(slug:"gmail",displayName:"Gmail",origin:origin,serverURL:nil,catalogID:nil,iconPath:nil,healthy:false,lastSeen:.now)
            let declared=ConnectorCensus.DetectedConnector(slug:"gmail",displayName:"Gmail",origin:origin,serverURL:nil,catalogID:nil,iconPath:nil,healthy:true,lastSeen:.now,readinessVerified:false,readinessAccountIdentity:origin == .claude ? "claude-a":nil)
            let refreshed=ConnectorCensus.preservingReadiness(staleCatalog,previous:declared)
            check(refreshed.canAttempt && refreshed.readinessVerified == false,"a stale catalog health check cannot re-block explicit Done for \(origin.rawValue)")
        }
        clear();ModelBackend.current = .chatgpt
        HostedConnectorSetup.confirm(slug:"gmail")
        CodexRuntime.accountIdentity="other-account"
        check(ConnectorCensus.cached(for:.chatgpt).isEmpty,"another ChatGPT account cannot inherit a declaration")
        CodexRuntime.accountIdentity="synthetic-account"
        check(ConnectorCensus.cached(for:.chatgpt).first?.canAttempt == true,"returning ChatGPT account retains its declaration")
        print("Hosted declarations and observed health: \(checks) checks passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='sentient-hosted-readiness-') as directory:
    path=Path(directory);(path/'main.swift').write_text('\n'.join((fixture,setup,checks)))
    subprocess.run(['xcrun','swiftc','-D','DEBUG','-parse-as-library',str(path/'main.swift'),'-o',str(path/'check')],check=True)
    subprocess.run([str(path/'check')],check=True,timeout=20)
