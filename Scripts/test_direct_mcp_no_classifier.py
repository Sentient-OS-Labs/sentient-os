#!/usr/bin/env python3
"""Check live-inventory access without classifier results; no network or app launch."""
from pathlib import Path
import subprocess,tempfile
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'
source=(APP/'Connectors/DirectMCPConnections.swift').read_text()
a=source.index('            // Provider annotations')
b=source.index('            // Closed provider/reason',a)
refresh=source[a:b]
fixture=r'''
import Foundation
nonisolated enum ConnectorRegistry {struct Pack {let directProvider:DirectMCPProvider?};static let packs:[Pack]=[]}
nonisolated enum ConnectorCensus {struct DetectedConnector {enum Origin {case direct};let slug:String;let displayName:String;let origin:Origin;let serverURL:String?;let catalogID:String?;let iconPath:String?;let healthy:Bool;let lastSeen:Date}}
@main struct Tests {
 static func refreshed(_ connection:DirectMCPConnection,_ tools:[DirectMCPTool])->DirectMCPConnection {
  var updated=connection;updated.tools=tools
  // REFRESH
  updated.state = .ready
  return updated
 }
 static func main()throws {
  func tool(_ name:String,_ read:Bool=false,_ destructive:Bool=false)throws->DirectMCPTool {
   let data=try JSONSerialization.data(withJSONObject:["name":name,"annotations":["readOnlyHint":read,"destructiveHint":destructive]])
   return .init(name:name,description:"Fixture",definition:data)
  }
  let tools=try [tool("renamed_reader_v2",true),tool("new_action_v3"),tool("delete_v4",false,true)]
  let old=DirectMCPConnection(id:UUID(),providerSlug:"fixture",label:"Test",generation:UUID(),state:.policyRequired)
  precondition(old.connected,"Old classifier failure must remain eligible for inventory refresh")
  let current=refreshed(old,tools)
  precondition(current.usable && current.actionNames==tools.map(\.name).sorted())
  precondition(current.readNames==["renamed_reader_v2"],"Background access uses read-only metadata")
  var stale=current;stale.policy=Dictionary(uniqueKeysWithValues:tools.map{($0.name,DirectMCPTool.Category.destructive)})
  precondition(stale.actionNames==current.actionNames,"Stale AI classifications cannot disable advertised actions")
  for failure in ["missing", "partial", "stale"] {
   var broken=current
   switch failure {
   case "missing": broken.policy=[:];broken.policyFingerprint=nil;broken.policyRevision=nil
   case "partial": broken.policy=[tools[0].name:.destructive]
   default: broken.policyFingerprint="old-inventory";broken.policyRevision=1
   }
   precondition(!broken.policyValid && broken.usable && broken.actionNames==current.actionNames,
                "Classification metadata must fail open for advertised actions")
   precondition(broken.readNames==current.readNames,"Read-only metadata remains independent of classification")
  }
  var failedSetup=current;failedSetup.state = .policyRequired;failedSetup.policy=[:]
  precondition(failedSetup.connected && failedSetup.actionNames==current.actionNames,
               "A previous classification failure can retry with all known tools")
  var disconnected=current;disconnected.state = .reconnect
  precondition(!disconnected.connected && !disconnected.usable,"Real authentication failures still need reconnecting")
  let renamed=refreshed(current,try [tool("brand_new_name")])
  precondition(renamed.usable && renamed.actionNames==["brand_new_name"],"New inventory needs no model or exact-name rule update")
  print("PASS direct MCP classifier removal and renamed-tool checks")
 }
}
'''.replace('// REFRESH',refresh)
with tempfile.TemporaryDirectory(prefix='sentient-no-classifier-') as directory:
 p=Path(directory);(p/'Tests.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5',str(APP/'Connectors/DirectMCPModels.swift'),str(p/'Tests.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
