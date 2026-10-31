#!/usr/bin/env python3
"""Exercise the production Granola reader, native MCP session/HTTP, parser and privacy filter.

A loopback-only server supplies fictional accounts/notes. Grant access, provider verification,
model replies and diagnostic sinks are controlled. No Keychain, app preferences, real provider,
user content, Sentry or analytics is accessed. Native request arguments are checked server-side.
"""
from pathlib import Path
import json, os, subprocess, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'
def block(s, marker):
    start=s.index(marker);end=s.index('{',start)+1;depth=1
    while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
    return s[start:end]
source=(APP/'Sources/MCPSource.swift').read_text()
parts=[block(source,x) for x in ['struct ReadResult:','enum ReadOutcome:','enum ReadMode:','struct Window:','static func parse(','private static func jsonSpan(']]
STUBS=r'''
import Foundation
import CoreFoundation
import os
nonisolated enum Fixture {
 static let state=OSAllocatedUnfairLock(initialState:(models:0,tokenReads:0,failures:[String](),summaries:0))
 static let id="11111111-1111-4111-8111-111111111111"
 static var scenario:String{ProcessInfo.processInfo.environment["GRANOLA_SCENARIO"]!}
 static func check(_ value:Bool,_ label:String){precondition(value,label);print("PASS "+label)}
}
nonisolated enum ConnectorRegistry {
 struct Pack:Sendable{let directProvider:DirectMCPProvider?}
 static let packs=[Pack(directProvider:.granola),Pack(directProvider:.notion)]
}
nonisolated enum ConnectorCensus {
 struct DetectedConnector:Sendable {
  enum Origin:Sendable{case direct}
  let slug:String,displayName:String;let origin:Origin;let serverURL:String?,catalogID:String?,iconPath:String?;let healthy:Bool;let lastSeen:Date
 }
}
nonisolated enum DirectMCPStore {
 static let value=OSAllocatedUnfairLock(initialState:Optional<DirectMCPConnection>.none)
 static func connection(id:UUID)->DirectMCPConnection?{value.withLock{$0?.id==id ? $0:nil}}
 static func connection(_ slug:String)->DirectMCPConnection?{value.withLock{$0?.slug==slug ? $0:nil}}
}
nonisolated enum DirectMCPAuth {
 static func accessToken(id:UUID,generation:UUID)async throws->String {
  try Task.checkCancellation()
  guard DirectMCPStore.connection(id:id)?.generation==generation else{throw DirectMCPError.connectionChanged}
  Fixture.state.withLock{$0.tokenReads+=1};return "synthetic-grant"
 }
}
nonisolated enum DirectMCPConnections {
 static func verify(_ c:DirectMCPConnection)async throws->DirectMCPConnection{try DirectMCPSession.check(c);return c}
}
nonisolated enum DirectMCPRuntime {
 static func executeNative<T>(connection:DirectMCPConnection,isolation:isolated(any Actor)? = #isolation,_ body:()async throws->T)async rethrows->T{try await body()}
}
nonisolated enum ClaudeCLI {enum Model:Sendable{case haiku,sonnet}}
nonisolated enum CodexCLI {
 enum CLIError:Error{case usageLimit,badEnvelope,exitFailure(Int32,String)}
 struct Envelope:Sendable{let result:String;let raw:String;var jsonResult:String{result}}
}
nonisolated enum Diagnostics {
 enum Phase {case validate,connect,identity,read}
 enum Event {case sourceReadFailed}
 static func withOperation<T>(_ name:StaticString,propagatesFailure:Bool=true,isolation:isolated(any Actor)? = #isolation,_ body:()async throws->T)async rethrows->T{try await body()}
 static func report(_ event:Event,phase:Phase,reason:StaticString,error:Error,source:String,terminal:Bool){Fixture.state.withLock{$0.failures.append(reason.description)}}
}
nonisolated enum CrashReporting {
 static func captureEvent(_ name:String,tags:[String:String],fingerprint:[String]){}
 static func diagnosticBreadcrumb(_ name:String,data:[String:String]){
  precondition(Set(data.keys).isSubset(of:["stage","reason"]))
  precondition(!data.values.contains(where:{$0.contains("synthetic@example")||$0.contains(Fixture.id)}))
 }
}
nonisolated func Log(_ value:String){}
nonisolated enum MCPSource {
 enum MCPError:Error{case invalidResponse(slug:String),connectorAuth(slug:String),toolFailure(slug:String)}
 typealias ReceiptObserver = @Sendable (CodexCLI.Envelope?, ReadOutcome?, Int, String, String, [String:Int]) -> Void
 static let readSchema="{}"
 static func shapeMismatch(slug:String,missing:String,len:Int){}
 static func timestamp(_ d:Date)->String{let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f.string(from:d)}
 static func model(prompt:String,schema:String,slug:String,claudeModel:ClaudeCLI.Model?)async throws->CodexCLI.Envelope{
  Fixture.state.withLock{$0.models+=1}
  if let index=prompt.range(of:"CANDIDATES: ") {
   let bytes=Data(prompt[index.upperBound...].utf8)
   let candidates=try JSONSerialization.jsonObject(with:bytes) as! [[String:Any]]
   let ids=Array(candidates.prefix(6)).compactMap{$0["id"] as? String}
   return .init(result:String(decoding:try DirectMCPHTTP.json(["ids":ids]),as:UTF8.self),raw:"")
  }
  let number=Fixture.state.withLock{value->Int in value.summaries+=1;return value.summaries}
  if Fixture.scenario=="summary_retry"&&number==1{return .init(result:"malformed",raw:"")}
  let summary=Fixture.scenario=="sensitive" ? "Card 4111 1111 1111 1111" : "A fictional project review is due."
  let failure=Fixture.scenario=="summary_failure" ? "other":""
  return .init(result:String(decoding:try DirectMCPHTTP.json(["item_count":1,"notable":true,"has_action_items":true,"summary":summary,"tool_failure":failure]),as:UTF8.self),raw:"")
 }
'''
TEST=r'''
}
@main enum Main {
 static func main()async throws {
  let account:[String:Any]=["email":"synthetic@example.test","workspace_id":"fixture-workspace","mcp_note_access":["scopes":["personal","public"]]]
  let fp=DirectMCPIdentity.parse(try DirectMCPHTTP.json(["structuredContent":account]))!.fingerprint
  let schema:[String:Any]=["type":"object","properties":["time_range":["type":"string","enum":["custom"]],"custom_start":["type":"string"],"custom_end":["type":"string"],"involvement":["type":"object","properties":["captured_by_me":["type":"boolean"],"listed_as_participant":["type":"boolean"]]]]]
  let tools=try ["get_account_info","list_meetings","get_meetings"].map{name in
   let input:[String:Any]=name=="list_meetings" ? schema : name=="get_meetings" ? ["type":"object","properties":["meeting_ids":["type":"array","items":["type":"string"],"minItems":1,"maxItems":2]]] : ["type":"object"]
   return DirectMCPTool(name:name,description:"Fixture",definition:try DirectMCPHTTP.json(["name":name,"inputSchema":input,"annotations":["readOnlyHint":true,"destructiveHint":false]]))
  }
  let connection=DirectMCPConnection(id:UUID(),providerSlug:"fixture",label:"Fixture",generation:UUID(),state:.ready,tools:tools,accountFingerprint:fp)
  DirectMCPStore.value.withLock{$0=connection}
  let window=MCPSource.Window(lower:GranolaSource.date("2026-10-01T00:00:00Z")!,upper:GranolaSource.date("2026-10-31T00:00:00Z")!,label:"Fictional")
  let run=Task {try await GranolaSource.read(connection:connection,prompt:"Summarize this fictional test.",mode:.initial,window:window,claudeModel:nil,onReceipt:nil)}
  if Fixture.scenario=="cancel" {try await Task.sleep(for:.milliseconds(200));run.cancel()}
  do {
   let result=try await run.value
   let successful=["json","json_xml_literal","xml","notice","account_notice","alias","mirror","sse","empty","summary_retry","sensitive","batch"]
   Fixture.check(successful.contains(Fixture.scenario),"only valid native paths succeed")
   let values=Fixture.state.withLock{$0}
   if Fixture.scenario=="empty"{Fixture.check(result.itemCount==0&&values.models==0,"empty native discovery makes no model/content call")}
   else if Fixture.scenario=="sensitive"{Fixture.check(result.result==nil&&result.itemCount==1,"privacy filtering omits sensitive summary")}
   else{Fixture.check(result.result != nil,"validated native notes reach a summary")}
   if Fixture.scenario=="summary_retry"{Fixture.check(values.summaries==2&&values.failures.isEmpty,"recovered summary attempt has no native terminal error")}
   Fixture.check(values.tokenReads>=4,"native requests re-read the unchanged grant")
   Fixture.check(values.failures.isEmpty,"successful native path has no failure diagnostics")
  } catch {
   Fixture.check(!["json","json_xml_literal","xml","notice","account_notice","alias","mirror","sse","empty","summary_retry","sensitive","batch"].contains(Fixture.scenario),"invalid native path fails")
   let values=Fixture.state.withLock{$0}
   if Fixture.scenario=="cancel"{Fixture.check(error is CancellationError&&values.failures.isEmpty,"Stop stays cancellation without native error telemetry")}
   else if Fixture.scenario=="summary_failure"{Fixture.check(values.models==1&&values.failures.isEmpty,"explicit summarizer failure remains terminal")}
   else {
    Fixture.check(values.models==0,"failed native evidence never reaches the model")
    let expected:[String:String]=["auth":"granola_owned_listing","rpc_error":"granola_owned_listing","malformed":"granola_owned_listing","missing_owner":"granola_owned_listing","wrong_owner":"granola_owned_listing","missing_content":"granola_content","account_changed":"granola_account_recheck","overflow":"granola_owned_listing","conflicting":"granola_owned_listing","non_text":"granola_owned_listing","malformed_error_flag":"granola_owned_listing","account_conflict":"granola_account"]
    Fixture.check(values.failures.last==expected[Fixture.scenario],"terminal failure records its exact native stage")
   }
  }
  print("SCENARIO "+Fixture.scenario+" passed")
 }
}
'''
ID='11111111-1111-4111-8111-111111111111'
DATE='2026-10-13T12:00:00.000Z'
account={'email':'synthetic@example.test','workspace_id':'fixture-workspace','mcp_note_access':{'scopes':['personal','public']}}
requests={}
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_DELETE(self):self.send_response(204);self.end_headers()
    def do_POST(self):
        scenario=self.path.strip('/');request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.setdefault(scenario,[]).append(request)
        assert self.headers.get('Authorization')=='Bearer synthetic-grant'
        method=request['method'];rid=request.get('id')
        if method=='notifications/initialized':self.send_response(202);self.end_headers();return
        if method=='initialize':result={'protocolVersion':'2025-11-25','capabilities':{'tools':{}},'serverInfo':{'name':'fixture','version':'1'}}
        else:
            assert method=='tools/call';tool=request['params']['name'];args=request['params']['arguments']
            assert tool in ['get_account_info','list_meetings','get_meetings']
            def payload(obj):return {'content':[{'type':'text','text':json.dumps(obj)}]}
            if tool=='get_account_info':
                number=sum(1 for r in requests[scenario]if r.get('params',{}).get('name')==tool)
                value=dict(account)
                if scenario=='account_changed' and number>1:value['workspace_id']='other-workspace'
                result=payload(value)
                if scenario=="account_notice":result["content"].append({"type":"text","text":"Provider account notice"})
                if scenario=="account_conflict":result["content"].append({"type":"text","text":json.dumps(dict(value,workspace_id="other-workspace"))})
            elif tool=='list_meetings':
                assert args['time_range']=='custom' and args['custom_start']=='2026-10-01T00:00:00.000Z' and args['custom_end']=='2026-10-31T00:00:00.000Z'
                owned=args['involvement']['captured_by_me'];assert args['involvement']==({'captured_by_me':True} if owned else {'captured_by_me':False,'listed_as_participant':True})
                if scenario=='cancel':time.sleep(2)
                count=8 if scenario=='batch' else 1
                rows=[{'id':ID if i==0 else f'{i+1:08d}-1111-4111-8111-111111111111','title':'Fictional review','created_at':DATE}for i in range(count)] if owned and scenario!='empty' else []
                obj={'count':len(rows),'total_in_range':len(rows),'date_range':{'from':args['custom_start'],'to':args['custom_end']},'meetings':rows}
                if scenario=='json_xml_literal':obj['note']='An explanation of <meetings_data> XML markup'
                if scenario in ['xml','missing_owner','wrong_owner']:
                    flags='' if scenario=='missing_owner' else f' captured_by_me="{str(owned if scenario!="wrong_owner" else not owned).lower()}" listed_as_participant="true"'
                    xml='<meetings_data count="'+str(len(rows))+'">'+''.join(f'<meeting id="{r["id"]}" title="Fictional review" date="Oct 13, 2026 5:00 AM PDT"{flags}/>'for r in rows)+'</meetings_data>'
                    result={'content':[{'type':'text','text':xml}]}
                elif scenario=='malformed':result={'content':[{'type':'text','text':'invalid'}]}
                elif scenario=='auth':result={'isError':True,'content':[{'type':'text','text':'Unauthorized'}]}
                elif scenario=='overflow':result={'content':[{'type':'text','text':'x'*410_000}]}
                elif scenario=='alias':result={'structured_content':obj}
                elif scenario=='notice':result=payload(obj);result['content'].append({'type':'text','text':'An untrusted provider notice.'})
                elif scenario=='mirror':result=payload(obj);result['structuredContent']=obj
                elif scenario=='conflicting':result=payload(obj);result['content'].append({'type':'text','text':json.dumps({'meetings':[],'count':0})})
                elif scenario=='non_text':result=payload(obj);result['content'].append({'type':'resource_link','uri':'https://example.test/unread'})
                elif scenario=='malformed_error_flag':result=payload(obj);result['isError']='false'
                else:result=payload(obj)
            else:
                assert 0<len(args['meeting_ids'])<=2
                rows=[{'id':x,'title':'Fictional review','created_at':DATE,'captured_by_me':True,'private_notes':'Review fictional draft next week.','enhanced_notes':'Review planned.'}for x in args['meeting_ids']]
                if scenario=='missing_content':rows=[]
                result=payload({'meetings':rows})
        envelope={'jsonrpc':'2.0','id':rid,'result':result}
        if scenario=='rpc_error' and method=='tools/call' and request['params']['name']=='list_meetings':envelope={'jsonrpc':'2.0','id':rid,'error':{'code':-32602,'message':'Fictional malformed request'}}
        body=json.dumps(envelope).encode()
        self.send_response(200);self.send_header('Content-Type','text/event-stream' if scenario=='sse' else 'application/json');self.send_header('Mcp-Session-Id','fixture-session');self.end_headers()
        try:
            if scenario=='sse':self.wfile.write(b'data: {"jsonrpc":"2.0","method":"notifications/progress"}\n\n'+b'data: '+body+b'\n\n')
            else:self.wfile.write(body)
        except(BrokenPipeError,ConnectionResetError):pass

server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
with tempfile.TemporaryDirectory(prefix='sentient-granola-native-')as tmp:
    path=Path(tmp);fixture=path/'Fixture.swift';fixture.write_text(STUBS+'\n'+'\n'.join(parts)+TEST)
    files=['Connectors/DirectMCPModels.swift','Connectors/DirectMCPResult.swift','Connectors/DirectMCPIdentity.swift','Connectors/DirectMCPSession.swift','Connectors/DirectMCPHTTP.swift','Sources/GranolaResponse.swift','Sources/GranolaSource.swift','Engine/PIIScan.swift']
    subprocess.run(['xcrun','swiftc','-D','DEBUG','-swift-version','6','-parse-as-library',str(fixture),*[str(APP/f)for f in files],'-o',str(path/'check')],check=True)
    scenarios=['json','json_xml_literal','xml','notice','account_notice','account_conflict','non_text','malformed_error_flag','alias','mirror','sse','empty','summary_retry','sensitive','batch','auth','rpc_error','malformed','missing_owner','wrong_owner','missing_content','account_changed','overflow','conflicting','cancel']
    for scenario in scenarios:
        env=dict(os.environ,GRANOLA_SCENARIO=scenario,SENTIENT_DIRECT_MCP_FIXTURE_URL=f'http://127.0.0.1:{server.server_port}/{scenario}')
        subprocess.run([str(path/'check')],env=env,check=True,timeout=15)
    for scenario,rows in requests.items():
        tools=[r['params']['name']for r in rows if r['method']=='tools/call']
        assert set(tools).issubset({'get_account_info','list_meetings','get_meetings'})
        if scenario in ['auth','rpc_error','malformed','missing_owner','wrong_owner','overflow','conflicting','non_text','malformed_error_flag']:assert tools==['get_account_info','list_meetings'],(scenario,tools)
        if scenario=='empty':assert 'get_meetings'not in tools
    print(f'PASS {len(scenarios)} native Granola session/read scenarios; only synthetic read tools used')
server.shutdown()
