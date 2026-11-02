#!/usr/bin/env python3
"""Check same-session Claude connector attachment with synthetic inventories, no provider or app."""
from pathlib import Path
import subprocess
import tempfile
APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"
def member(source, signature):
    start=source.index(signature); end=source.index("{",start)+1; depth=1
    while depth:
        depth+=(source[end]=="{")-(source[end]=="}"); end+=1
    return source[start:end]
wall=member((APP/"Cloud/ClaudeCLI.swift").read_text(),"static func mcpServerAllowSettings(")
support=r'''
import Foundation
nonisolated enum ModelBackend {case claude,chatgpt,custom,sentient;nonisolated(unsafe) static var current=Self.claude}
nonisolated enum ConnectorCensus {
 struct Connector {let slug:String}
 nonisolated(unsafe) static var slugs:[String]=[]
 static func cached(for backend:ModelBackend)->[Connector]{slugs.map{Connector(slug:$0)}}
}
nonisolated enum ConnectorRegistry {
 enum Category {case read,write,destructive}
 struct Tool {let name:String;let category:Category}
 struct Classification {let tools:[Tool]}
 struct Server {let directConnection:Bool?;let claudeServerURL:String?;let claudeToolPrefix:String?}
 nonisolated(unsafe) static var fresh=false
 static func prefix(_ slug:String)->String {"mcp__"+(["outlook-mail","outlook-calendar"].contains(slug) ? "m365" : slug)+"__"}
 static func names(_ slug:String)->[String]{
  if ["outlook-mail","outlook-calendar"].contains(slug){return ["read_mail","send_mail","read_calendar","create_event","delete"]}
  return ["read","send","delete","*"]
 }
 static func server(for slug:String)->Server? {Server(directConnection:slug=="direct" ? true:nil,claudeServerURL:"https://"+slug+".example/mcp",claudeToolPrefix:prefix(slug))}
 static func isClassified(_ slug:String)->Bool{fresh}
 static func classification(for slug:String)->Classification?{Classification(tools:names(slug).map{Tool(name:prefix(slug)+$0,category:$0=="delete" ? .destructive:.write)})}
 static func readToolNames(slug:String)->[String]{[prefix(slug)+(slug=="outlook-mail" ? "read_mail":slug=="outlook-calendar" ? "read_calendar":"read")]}
 static func allKnownToolNames(slug:String)->[String]{names(slug).map{prefix(slug)+$0}}
 static func displayName(slug:String)->String{slug}
 static func actionInstructions(slug:String)->String{"Policy for "+slug}
}
nonisolated enum SlackConnector {
 enum Operation {case read,write}
 static func actionTools(backend:ModelBackend,operation:Operation)->[String]{operation == .read ? ["read"]:["read","send"]}
}
nonisolated enum OutlookMailConnector {
 static let slug="outlook-mail";enum Operation {case read,write}
 static func actionTools(_ backend:ModelBackend,operation:Operation)->[String]{operation == .read ? ["read_mail"]:["read_mail","send_mail"]}
}
nonisolated enum OutlookCalendarConnector {
 static let slug="outlook-calendar";enum Operation {case read}
 static func actionTools(_ backend:ModelBackend,operation:Operation)->[String]{["read_calendar"]}
}
nonisolated enum OutlookCalendarToolPolicy {struct Context {let operation:OutlookCalendarConnector.Operation}}
nonisolated enum SlackToolPolicy {
 static func claudeSettings(_ base:String,operation:SlackConnector.Operation,runID:UUID)throws->String {
  var object=try JSONSerialization.jsonObject(with:Data(base.utf8)) as! [String:Any];object["fixtureSlackHook"]=true
  return String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self)
 }
}
nonisolated enum OutlookToolPolicy {
 static func claudeSettings(_ base:String,operation:OutlookMailConnector.Operation,runID:UUID,calendar:OutlookCalendarToolPolicy.Context?,includesMail:Bool)throws->String {
  var object=try JSONSerialization.jsonObject(with:Data(base.utf8)) as! [String:Any];object["fixtureMailHook"]=includesMail;object["fixtureCalendarHook"]=calendar != nil
  return String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self)
 }
}
'''
tests=r'''
@main struct Tests {
 static func main()throws {
  UserDefaults.standard.setVolatileDomain(["dbg.gmail.connected":false,"dbg.calendar.connected":false],forName:UserDefaults.argumentDomain)
  defer{UserDefaults.standard.removeVolatileDomain(forName:UserDefaults.argumentDomain)}
  let base=["-p","--permission-mode","dontAsk","--tools","WebSearch,WebFetch","--allowedTools","mcp__sentient_relay__*,WebSearch,WebFetch","--strict-mcp-config","--mcp-config","/fixture/relay.json","--setting-sources",""]
  var count=0
  func check(_ value:Bool,_ why:String){precondition(value,why);count+=1}
  func plan()throws->ClaudeComputerUseConnectors{try .current(runID:UUID())}
  check(try plan().applying(to:base,relayURL:"http://127.0.0.1:32123/mcp")==base,"No connectors keeps strict relay-only invocation")
  ConnectorCensus.slugs=["gmail"]
  var selected=try plan()
  check(selected.allowed==["mcp__gmail__*"],"Connected server exposes its current tools without a per-tool list")
  check(selected.denied.isEmpty,"No classification-derived or hardcoded tool denies")
  let args=try selected.applying(to:base,relayURL:"http://127.0.0.1:32123/mcp")
  check(!args.contains("--strict-mcp-config") && args.contains("/fixture/relay.json"),"Hosted connectors and native relay coexist")
  check(args.contains("dontAsk") && args.contains("WebSearch,WebFetch,WaitForMcpServers"),"Existing session permission mode and discovery tools remain")
  let allows=args[args.firstIndex(of:"--allowedTools")!+1]
  check(allows.contains("mcp__sentient_relay__*") && allows.contains("mcp__gmail__*"),"Renamed or new tools on the connected server need no reclassification")
  let settings=try JSONSerialization.jsonObject(with:Data(selected.settings!.utf8)) as! [String:Any]
  let servers=settings["allowedMcpServers"] as! [[String:String]]
  check(servers.contains(["serverName":"sentient_relay"]) && servers.contains(["serverUrl":"https://gmail.example/*"]),"Server boundary permits only connected endpoints and relay")
  let resolved=try JSONSerialization.jsonObject(with:Data(args[args.firstIndex(of:"--settings")!+1].utf8)) as! [String:Any]
  let resolvedServers=resolved["allowedMcpServers"] as! [[String:String]]
  check(resolvedServers.contains(["serverUrl":"http://127.0.0.1:32123/mcp"]),"HTTP relay is allowed by URL alongside hosted URL rules")
  check(!resolvedServers.contains(["serverUrl":"http://127.0.0.1/*"]),"Local relay grant is restricted to its exact ephemeral endpoint")

  ConnectorCensus.slugs=["outlook-mail","outlook-calendar","slack"]
  selected=try plan()
  check(Set(selected.allowed)==["mcp__m365__*","mcp__slack__*"],"Shared namespaces deduplicate without filtering tool names")
  let hooks=try JSONSerialization.jsonObject(with:Data(selected.settings!.utf8)) as! [String:Any]
  check(hooks["fixtureSlackHook"] == nil && hooks["fixtureMailHook"] == nil,"Main session has no exact-name policy hooks")
  for backend in [ModelBackend.chatgpt,.custom,.sentient]{ModelBackend.current=backend;check(try plan().applying(to:base,relayURL:"http://127.0.0.1:32123/mcp")==base,"Subscription connector attachment cannot leak into another backend")}
  ModelBackend.current = .claude;ConnectorCensus.slugs=["direct"]
  check(try plan().applying(to:base,relayURL:"http://127.0.0.1:32123/mcp")==base,"Direct connections continue through the existing Codex relay")
  print("PASS \(count) same-agent Claude connector checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix="sentient-claude-connectors-") as directory:
    path=Path(directory);(path/"Fixture.swift").write_text(support+"\nactor ClaudeCLI {\n"+wall+"\n}\n"+tests)
    subprocess.run(["xcrun","swiftc","-parse-as-library","-swift-version","5","-default-isolation","MainActor",str(APP/"Cloud/ClaudeComputerUseConnectors.swift"),str(path/"Fixture.swift"),"-o",str(path/"test")],check=True)
    subprocess.run([str(path/"test")],check=True)
