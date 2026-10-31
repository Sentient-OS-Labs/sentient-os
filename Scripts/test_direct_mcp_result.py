#!/usr/bin/env python3
"""Check production MCP envelope normalization and identity conflicts on fictional payloads."""
from pathlib import Path
import subprocess,tempfile
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'
def block(s,m):
 b=s.index(m);e=s.index('{',b)+1;d=1
 while d:d+=(s[e]=='{')-(s[e]=='}');e+=1
 return s[b:e]
source='import Foundation\nimport CoreFoundation\nimport Security\n'+block((APP/'Connectors/DirectMCPModels.swift').read_text(),'nonisolated enum DirectMCPError:')
source+=r'''
nonisolated enum DirectMCPHTTP{static func json(_ v:Any)throws->Data{try JSONSerialization.data(withJSONObject:v,options:[.sortedKeys])}}
nonisolated enum MCPSource{static func timestamp(_ d:Date)->String{let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f.string(from:d)}}
nonisolated enum GranolaSource{static let responseByteCap=400_000,inventoryCap=500,noteByteCap=24_000
'''
granola=(APP/'Sources/GranolaSource.swift').read_text();source+='\n'.join(block(granola,m)for m in ['static func date(','static func verifiedURL('])+'\n}\n'
source+=r'''
@main enum Main {
 static func main()throws{
  var checks=0
  func check(_ condition:Bool,_ label:String){precondition(condition,label);checks+=1;print("PASS "+label)}
  func rejects(_ label:String,_ operation:()throws->Void){do{try operation();preconditionFailure(label)}catch{checks+=1;print("PASS "+label)}}
  let a:[String:Any]=["email":"synthetic@example.test","workspace_id":"synthetic-a"]
  let b:[String:Any]=["email":"synthetic@example.test","workspace_id":"synthetic-b"]
  func text(_ object:[String:Any])throws->[String:Any]{["type":"text","text":String(decoding:try DirectMCPHTTP.json(object),as:UTF8.self)]}
  func identity(_ envelope:[String:Any])throws->DirectMCPIdentity.Identity?{DirectMCPIdentity.parse(try DirectMCPHTTP.json(envelope))}
  let original=try identity(["content":[text(a)]])!
  let notice:[String:Any]=["type":"text","text":"An ordinary provider notice"]
  check(try identity(["content":[text(a),notice]])?.fingerprint==original.fingerprint,"plain notice does not discard explicit native identity")
  check(try identity(["structuredContent":a,"structured_content":a,"content":[text(a)]])?.fingerprint==original.fingerprint,"equivalent account mirrors are one identity")
  check(try identity(["content":[text(a),text(b)]])==nil,"different workspace identities cannot pick first block")
  check(try identity(["structuredContent":a,"content":[text(b)]])==nil,"structured and text identity disagreement fails")
  check(try identity(["structuredContent":a,"content":[text(["error":"Synthetic failure"])]])==nil,"explicit failed object cannot be hidden beside account")
  check(try identity(["isError":true,"structuredContent":a])==nil,"explicit tool failure cannot certify account")
  check(try identity(["isError":1,"structuredContent":a])==nil,"numeric status is not a boolean error flag")
  check(try identity(["isError":false,"is_error":true,"structuredContent":a])==nil,"an explicit error alias wins over false mirror")
  check(try identity(["structuredContent":a,"content":Array(repeating:notice,count:31)+[text(a)]])?.fingerprint==original.fingerprint,"bounded thirty-two content blocks remain supported")
  check(try identity(["structuredContent":a,"content":Array(repeating:notice,count:32)+[text(b)]])==nil,"over-limit block count cannot hide another identity")
  check(try identity(["structuredContent":a,"content":[["type":"text","text":123]]])==nil,"malformed text mirror cannot be ignored")
  check(try identity(["structuredContent":a,"content":"not an array"])==nil,"malformed content container cannot certify account")
  check(try identity(["structuredContent":NSNull(),"content":[text(a)]])==nil,"null structured payload cannot be ignored by identity")
  check(try identity(["structured_content":[1,2],"content":[text(a)]])==nil,"invalid structured alias cannot be ignored by identity")
  check(try identity(["structuredContent":a,"content":[["text":String(decoding:try DirectMCPHTTP.json(b),as:UTF8.self)]]])==nil,"type-less block cannot hide conflicting identity")
  check(try identity(["structuredContent":a,"content":[["type":123,"text":"invalid"]]])==nil,"non-string content type is not silently ignored")
  check(try identity(["structuredContent":a,"content":[["type":"unknown","text":"invalid"]]])==nil,"unknown content type cannot certify account")
  let listing:[String:Any]=["meetings":[[String:Any]](),"count":0,"note":"Literal <meetings_data> example"]
  check(try GranolaResponse.decode(["content":[text(listing),notice]]).object["count"]as?Int==0,"JSON string containing XML syntax remains a single payload")
  check(try GranolaResponse.decode(["structuredContent":listing,"content":[text(listing),notice]]).object["count"]as?Int==0,"Granola accepts equivalent structured/text mirror")
  check(try GranolaResponse.decode(["structured_content":listing]).object["count"]as?Int==0,"Granola and identity accept the same structured-content alias")
  rejects("conflicting native listing objects remain failures") { _=try GranolaResponse.decode(["content":[text(listing),text(["count":1,"meetings":[["id":"conflicting"]]])]]) }
  rejects("unread resource block cannot become quiet") { _=try GranolaResponse.decode(["structuredContent":listing,"content":[["type":"resource_link","uri":"https://example.test/unread"]]]) }
  rejects("explicit structured error cannot be hidden") { _=try GranolaResponse.decode(["structuredContent":listing,"content":[text(["error":"Synthetic failure"])]]) }
  rejects("too many result blocks fail rather than silently truncating") { _=try GranolaResponse.decode(["structuredContent":listing,"content":Array(repeating:notice,count:33)]) }
  rejects("malformed error status does not certify success") { _=try GranolaResponse.decode(["isError":"false","structuredContent":listing]) }
  rejects("non-object structured data cannot mask valid text") { _=try GranolaResponse.decode(["structuredContent":[1,2],"content":[text(listing)]]) }
  rejects("byte cap remains enforced") { _=try GranolaResponse.decode(["structuredContent":["meetings":[],"count":0,"extra":String(repeating:"x",count:400_001)]]) }
  print("PASS \(checks) native envelope and identity checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-mcp-result-')as tmp:
 p=Path(tmp);(p/'main.swift').write_text(source)
 files=['Connectors/DirectMCPResult.swift','Connectors/DirectMCPIdentity.swift','Sources/GranolaResponse.swift']
 subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(p/'main.swift'),*[str(APP/f)for f in files],'-o',str(p/'check')],check=True)
 subprocess.run([str(p/'check')],check=True)
