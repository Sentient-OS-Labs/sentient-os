#!/usr/bin/env python3
"""Regress hosted intent, explicit direct setup and exact account binding.

Compile production routing predicates against synthetic, in-memory dependencies.
No network, Keychain, real preferences, app process or knowledge store is accessed.
This verifies local branch reachability, not a provider read or end-to-end UI run.
"""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parent
REPO=ROOT.parent
SRC=REPO/'Sentient OS macOS'
def method(path,needle):
 s=(SRC/path).read_text();start=s.index(needle);brace=s.index('{',start);depth=1;i=brace+1
 while depth:
  if s[i]=='{':depth+=1
  elif s[i]=='}':depth-=1
  i+=1
 return s[start:i]
registry='\n'.join(method('Cloud/ConnectorRegistry.swift',x) for x in [
 'static func pack(forSlug','static func canonicalSlug','static func pack(for connector',
 'static func kbKey','static func isKBEnabled','static func setKBEnabled','static func advanceKnowledgeSelectionRevision','static func kbEnabledConnectors',
 'static func contributesToKnowledgeBase','static func kbEligible','static func requiresDirectKnowledgeConnection',
 'static func detectedForCurrentBackend'])
require=method('Sources/MCPSource.swift','private static func requireReadable').replace('private static','static',1)
confirm=method('Cloud/HostedConnectorSetup.swift','static func confirm(slug:')
lookup=method('Connectors/DirectMCPStore.swift','static func connection(_ slug:')
can=method('Cloud/ConnectorCensus.swift','var canAttempt: Bool')
source=(SRC/'Views/Settings/ConnectorsSection.swift').read_text();source=source[source.index('struct ConnectorSource:'):source.index('/// Green means')]
fixture=r'''
import Foundation
final class UserDefaults {
 static let standard=UserDefaults();var v:[String:Any]=[:]
 func bool(forKey k:String)->Bool{v[k] as? Bool ?? false}
 func string(forKey k:String)->String?{v[k] as? String}
 func set(_ value:Any,forKey k:String){v[k]=value}
}
enum ModelBackend:String {case chatgpt,claude,custom,sentient
 static var current:Self = .chatgpt
 var hasSubscriptionConnectors:Bool{self == .chatgpt || self == .claude}
}
enum CodexAuth{static let kbOnlyKey="kbOnly"}
enum OutlookMailConnector{static let codexSlug="outlook-email";static let slug="outlook-mail"}
struct DirectMCPProvider{let slug:String;let kbVerified:Bool;let reviewedReads:Set<String>
 static let notion=Self(slug:"notion",kbVerified:true,reviewedReads:["notion-fetch","notion-list-recent-pages"])
 static let granola=Self(slug:"granola",kbVerified:true,reviewedReads:["list_meetings","get_meetings"])
}
struct DirectMCPConnection{let id:UUID;let generation:UUID;let providerSlug:String
 var connected=true
 var slug:String{"direct-"+id.uuidString.lowercased()}
 var kbEligible:Bool{true};var kbPolicyReady:Bool{true}
 var detected:ConnectorCensus.DetectedConnector{.init(slug:slug,displayName:providerSlug,origin:.direct)}
}
enum DirectMCPStore{static var records:[DirectMCPConnection]=[];static func connections()->[DirectMCPConnection]{records}
 static func connection(id:UUID)->DirectMCPConnection?{records.first{$0.id == id}}
LOOKUP
}
enum ConnectorCensus{
 struct DetectedConnector:Identifiable{
  enum Origin:String{case chatgpt,claude,direct,sentient
   init?(backend:ModelBackend){switch backend{case .chatgpt:self = .chatgpt;case .claude:self = .claude;default:return nil}}
  }
  let slug:String;var displayName:String;let origin:Origin
  var serverURL:String?=nil;var catalogID:String?=nil;var iconPath:String?=nil;var healthy=false;var lastSeen=Date.distantPast
  var id:String{origin.rawValue+":"+slug}
  CAN
 }
 static var records:[DetectedConnector]=[]
 static let dedicatedSourceSlugs:Set<String>=["gmail","google-calendar"]
 static func cached(for origin:DetectedConnector.Origin)->[DetectedConnector]{records.filter{$0.origin == origin}}
 static func confirmSelection(slug:String,reconnected:Bool){
  if !records.contains(where:{$0.slug==slug}){records.append(.init(slug:slug,displayName:slug,origin:.init(backend:ModelBackend.current)!))}
 }
}
struct CuratedConnector{
 let slug:String;let displayName:String;var directProvider:DirectMCPProvider?=nil
 var capturedProvisional=false;var claudeServerURL:String?=nil;var claudeToolPrefix:String?=nil
 var codexCatalogID:String?=nil;var readTools:[String]?=nil;var codexReadTools:[String]?=nil
}
enum HostedConnectorStore {
 struct Account { let service:String;let connected:Bool;let detected:ConnectorCensus.DetectedConnector }
 static func accounts()->[Account]{[]}
 static func account(_ slug:String)->Account?{nil}
}
enum ConnectorRegistry{
 static let packs:[CuratedConnector]=[
 .init(slug:"notion",displayName:"Notion",directProvider:.notion),
 .init(slug:"granola",displayName:"Granola",directProvider:.granola),
 .init(slug:"slack",displayName:"Slack",claudeServerURL:"https://example.invalid",claudeToolPrefix:"mcp__slack__",codexCatalogID:"connector_00000000000000000000000000000000",readTools:["slack_search_public"],codexReadTools:["slack_search_public"]),
 .init(slug:"google-drive",displayName:"Drive",claudeServerURL:"https://example.invalid",claudeToolPrefix:"mcp__drive__",codexCatalogID:"connector_11111111111111111111111111111111",readTools:["search"],codexReadTools:["search"])]
 REGISTRY
 struct Server{let codexCatalogID:String?}
 static func telemetrySlug(_ slug:String)->String{DirectMCPStore.connection(slug)?.providerSlug ?? pack(forSlug:slug)?.slug ?? "other"}
 static func server(for slug:String)->Server?{.init(codexCatalogID:"connector_00000000000000000000000000000000")}
}
@MainActor enum HostedConnectorSetup{
 static var teardownDepth=0
 static func mailCollectionRequest(slug:String,backend:ModelBackend)->(key:String,unused:Int)?{nil}
 CONFIRM
}
enum CodexCLI{
 struct Invocation{}
 static func arguments(for inv:Invocation,modelID:String,effortArg:String,schemaFile:String?)throws->[String]{[]}
}
enum ClaudeCLI{static func arguments(for inv:CodexCLI.Invocation,modelID:String,effortArg:String)throws->[String]{[]}}
enum GranolaSource{static var curationTrial=false}
enum MCPSource{
 enum MCPError:Error{case noReadSurface(slug:String),connectorAuth(slug:String),directConnectionRequired(slug:String)}
 static func readInvocation(slug:String,prompt:String)->CodexCLI.Invocation{.init()}
 REQUIRE
 ATTRIBUTION
}
SOURCE
struct SheetFixture {
 let source:ConnectorSource
 var newConnectionID:UUID?=nil
 var boundConnectorID:String?=nil
 var repairingHostedKnowledge=false
 var connectors:[ConnectorCensus.DetectedConnector]=[]
 var selected:ConnectorCensus.DetectedConnector? {connector}
 var native:Bool {usesDirect}
 CONNECTOR
 DIRECT
}
func check(_ x:Bool,_ name:String){precondition(x,name);print("PASS: "+name)}
@main struct Main{
 @MainActor static func main()throws{
  for backend in [ModelBackend.chatgpt,.claude]{
   ModelBackend.current=backend
   for slug in ["notion","granola"]{
    DirectMCPStore.records=[];ConnectorCensus.records=[];UserDefaults.standard.v=[:]
    let empty=ConnectorSource.catalog(with:[]).first{$0.serviceSlug==slug}!
    check(!empty.usesHostedConnection,"\(backend) catalog-only \(slug) chooses direct setup")
    let hosted=ConnectorCensus.DetectedConnector(slug:slug,displayName:slug,origin:.init(backend:backend)!)
    ConnectorCensus.records=[hosted]
    let detected=ConnectorSource.catalog(with:[hosted]).first{$0.serviceSlug==slug}!
    check(detected.usesHostedConnection,"\(backend) detected hosted \(slug) keeps hosted route")
    let catalog=ConnectorSource.catalog(with:[hosted])
    check(catalog.count == ConnectorRegistry.packs.count + 1,"hosted record keeps separate direct setup tile")
    let setup=catalog.first{$0.serviceSlug==slug && $0.isDirectSetup}!
    let sheet=SheetFixture(source:setup,connectors:[hosted])
    check(sheet.selected == nil && sheet.native,"direct setup does not bind the existing hosted account")
    let repairSheet=SheetFixture(source:detected,boundConnectorID:hosted.id,repairingHostedKnowledge:true,connectors:[hosted])
    check(repairSheet.selected == nil && repairSheet.native,"explicit repair waits for the account the user chooses")
    check(ConnectorRegistry.canonicalSlug(slug)==slug,"\(slug) has no direct alias")
    check(HostedConnectorSetup.confirm(slug:slug,backend:backend),"Done accepts \(backend) hosted \(slug)")
    check(ConnectorRegistry.isKBEnabled(slug),"Done selects bare \(slug) KB key")
    let attempts=ConnectorRegistry.kbEnabledConnectors().filter(\.canAttempt).map(\.slug)
    check(attempts.contains(slug),"\(backend) hosted \(slug) reaches processing admission")
    do{try MCPSource.requireReadable(slug);fatalError("unexpected readable")}
    catch MCPSource.MCPError.directConnectionRequired(let bad){check(bad==slug,"\(backend) hosted \(slug) reports required direct setup, never false authentication failure")}
    let direct=DirectMCPConnection(id:UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,generation:UUID(uuidString:"00000000-0000-0000-0000-000000000002")!,providerSlug:slug)
    DirectMCPStore.records=[direct]
    check(DirectMCPStore.connection(slug)==nil,"same-provider direct account cannot satisfy bare hosted slug")
    try MCPSource.requireReadable(direct.slug)
    var unavailable=direct;unavailable.connected=false;DirectMCPStore.records=[unavailable]
    check(ConnectorRegistry.detectedForCurrentBackend(includeUnavailableDirect:true).contains{$0.slug==direct.slug},
      "management refresh retains failed direct accounts for repair after hosted Done")
    check(!ConnectorRegistry.detectedForCurrentBackend().contains{$0.slug==direct.slug},
      "task discovery does not gain unavailable direct accounts from management refresh")
    DirectMCPStore.records=[direct]
    let both=ConnectorSource.catalog(with:[hosted,direct.detected])
    check(both.filter{$0.serviceSlug==slug}.count == 3,"hosted, direct account and add-account routes remain distinct")
    let chosen=SheetFixture(source:setup,newConnectionID:direct.id,connectors:[hosted,direct.detected])
    check(chosen.selected?.slug == direct.slug && chosen.native,"completed setup binds the exact chosen direct account")
    check(true,"stored \(slug) direct UUID passes route admission")
    ConnectorCensus.records=[]
    check(ConnectorRegistry.kbEnabledConnectors().contains{$0.slug==slug},"bare \(slug) selection survives missing catalog cache")
    check(ConnectorRegistry.requiresDirectKnowledgeConnection(slug),"missing metadata leaves hosted choice actionable for \(slug)")
    let recovered=ConnectorSource.catalog(with:[]).filter{$0.serviceSlug == slug}
    check(recovered.contains{$0.usesHostedConnection} && recovered.contains{$0.isDirectSetup},"cache loss preserves both selected route and explicit direct repair")
    let directAttribution=MCPSource.ReadAttribution(slug:direct.slug,backend:backend)
    DirectMCPStore.records=[]
    check(directAttribution.target==slug && directAttribution.route=="direct" && directAttribution.backend==backend.rawValue,
      "read outcome keeps captured provider/route/backend after account deletion")
    check(![directAttribution.target,directAttribution.route,directAttribution.backend].contains{ $0.contains(direct.id.uuidString.lowercased()) },
      "structural read attribution never carries an account UUID")
    let hostedAttribution=MCPSource.ReadAttribution(slug:slug,backend:backend)
    check(hostedAttribution.route==backend.rawValue+"_hosted","unsupported hosted read is attributed to its intended route")
   }
   for slug in ["slack","google-drive"]{
    ConnectorCensus.records=[];DirectMCPStore.records=[];UserDefaults.standard.v=[:]
    check(HostedConnectorSetup.confirm(slug:slug,backend:backend),"\(backend) \(slug) Done control")
    try MCPSource.requireReadable(slug)
    check(true,"\(backend) \(slug) passes local read-policy branch with synthetic valid server")
   }
  }
 }
}
'''
for key,value in [('LOOKUP',lookup),('CAN',can),('REGISTRY',registry),('CONFIRM',confirm),('REQUIRE',require),('ATTRIBUTION',method('Sources/MCPSource.swift','private struct ReadAttribution').replace('private struct','struct',1)),('SOURCE',source),('CONNECTOR',method('Views/Settings/ConnectorConnectSheet.swift','private var connector:')),('DIRECT',method('Views/Settings/ConnectorConnectSheet.swift','private var usesDirect:'))]:fixture=fixture.replace(key,value)
with tempfile.TemporaryDirectory(prefix='sentient-connector-routes-') as directory:
 path=Path(directory);(path/'fixture.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(path/'fixture.swift'),'-o',str(path/'check')],check=True)
 subprocess.run([str(path/'check')],check=True,timeout=30)
 print('PASS connector route selection, capability, cache recovery and exact-account setup')
