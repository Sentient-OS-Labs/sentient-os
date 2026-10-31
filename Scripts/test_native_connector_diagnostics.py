#!/usr/bin/env python3
"""Verify production native connector error fields keep closed codes and exclude content."""
from pathlib import Path
import subprocess,tempfile
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'
def block(s,m):
 b=s.index(m);e=s.index('{',b)+1;d=1
 while d:d+=(s[e]=='{')-(s[e]=='}');e+=1
 return s[b:e]
source=r'''
import Foundation
import Security
nonisolated enum ConnectorClassificationDiagnostics {struct Failure:Error{let reasonCode:String}}
nonisolated enum OpenAIComputerUse {enum RuntimeError:Error{case synthetic}}
nonisolated struct NativeComputerUseFailure:Error {enum Kind:String{case synthetic};let kind=Kind.synthetic;let fields:[String:String]=[:]}
nonisolated enum MirrorClient{enum MirrorError:Error{case http(Int,String)}}
nonisolated enum DoubleTapInference{enum Failure:Error{case http(Int,String)}}
nonisolated enum CodexCLI{enum CLIError:Error{case exitFailure(Int32,String)}}
'''
source+=block((APP/'Connectors/DirectMCPModels.swift').read_text(),'nonisolated enum DirectMCPError:')
source+='\nnonisolated enum GranolaResponse {\n'+block((APP/'Sources/GranolaResponse.swift').read_text(),'nonisolated enum Failure:')+'\n}\n'
source+='\nnonisolated enum Diagnostics {\n'+block((APP/'Diagnostics/Diagnostics.swift').read_text(),'static func errorFields(')+'\n}\n'
source+=r'''
@main enum Main {
 static func main(){
  let cases:[(Error,String)]=[(DirectMCPError.invalidResponse,"invalid_response"),(.http(429) as DirectMCPError,"http"),(.keychain(-25308) as DirectMCPError,"keychain"),(.connectionChanged as DirectMCPError,"connection_changed"),(.reconnectRequired as DirectMCPError,"reconnect_required"),(GranolaResponse.Failure.listingDate,"listing_date"),(.listingOwnership as GranolaResponse.Failure,"listing_ownership"),(.ambiguousPayload as GranolaResponse.Failure,"ambiguous_payload")]
  for(error,expected)in cases{
   let fields=Diagnostics.errorFields(error)
   precondition(fields["error_case"]==expected)
   precondition(fields.keys.allSatisfy{["error_type","error_case","error_domain","error_code","http_status"].contains($0)})
   print("PASS stable native error case "+expected)
  }
  precondition(Diagnostics.errorFields(DirectMCPError.http(429))["http_status"]=="429")
  let privateText="Synthetic user content must stay local"
  let fields=Diagnostics.errorFields(CodexCLI.CLIError.exitFailure(1,privateText))
  precondition(!fields.values.contains(where:{$0.contains(privateText)}))
  print("PASS native diagnostics retain numeric status and exclude associated content")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-native-diagnostics-')as tmp:
 p=Path(tmp);(p/'main.swift').write_text(source)
 subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(p/'main.swift'),'-o',str(p/'check')],check=True)
 subprocess.run([str(p/'check')],check=True)
