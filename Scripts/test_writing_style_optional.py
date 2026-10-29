#!/usr/bin/env python3
"""Exercise real optional-style packing and exclusive publication using scratch files only.
No source collection, model/network request, credential lookup, or app launch is performed.
"""
from pathlib import Path
import subprocess
import tempfile
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'

def member(source,signature):
    start=source.index(signature);end=source.index('{',start)+1;depth=1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[start:end]

writing=(APP/'Vault/WritingStyle.swift').read_text()
inference=(APP/'Double Tap/DoubleTapInference.swift').read_text()
fixture=r'''
import Foundation
import Darwin
enum VaultGenerator { static var vaultRoot:URL{URL(fileURLWithPath:CommandLine.arguments[1])} }
enum Diagnostics {
    enum Event{case knowledgeFailed,doubleTapFailed};enum Phase{case publish,read};enum Count{case skipped}
    static func report(_ event:Event,phase:Phase,reason:String,source:String?=nil,counts:[Count:Int]=[:]){}
    static func report(_ event:Event,phase:Phase,reason:String,error:Error){}
}
final class VaultActivity{static let shared=VaultActivity();var changed=0;func markChanged(){changed+=1}}
func Log(_ value:String){}
enum WritingStyle {
    static let fileName="writingstyle.md"
// WRITING
}
enum DoubleTapInference {
    static let vaultByteCeiling=600_000
    enum Failure:Error{case noVault(String),writingStyleTooLarge}
// PACKING
}
@main struct Test {
    @MainActor static func main()throws{
        var checks=0
        func check(_ result:Bool,_ label:String){precondition(result,label);checks+=1;print("PASS "+label)}
        let root=VaultGenerator.vaultRoot,fm=FileManager.default
        let readme=root.appendingPathComponent("README.md"),style=root.appendingPathComponent(WritingStyle.fileName)
        try "# Fixture knowledge\nA useful project.".write(to:readme,atomically:true,encoding:.utf8)
        let absent=try DoubleTapInference.packVault(root)
        check(absent.notes==1 && absent.text.contains("Fixture knowledge"),"missing style still packs valid knowledge for Double Tap")
        check(!absent.text.contains("WRITING SAMPLES"),"absent samples are not represented as fabricated examples")
        let blank=root.appendingPathComponent("Blank.md")
        try " \n\t".write(to:blank,atomically:true,encoding:.utf8)
        check(try DoubleTapInference.packVault(root).notes==1,"blank notes do not count as usable knowledge")
        try fm.removeItem(at:blank)
        try WritingStyle.publishIfNeeded("",in:root)
        try WritingStyle.publishIfNeeded(" \n\t",in:root)
        check(!WritingStyle.exists(in:root) && VaultActivity.shared.changed==0,"empty automatic collection creates no permanent snapshot or sync write")
        try WritingStyle.publishIfNeeded("To Fixture (email)\nhello :)\n",in:root)
        let original=try Data(contentsOf:style)
        check(WritingStyle.exists(in:root),"later authorized samples can populate the previously absent file")
        try WritingStyle.publishIfNeeded("AUTOMATIC REPLACEMENT",in:root)
        try WritingStyle.publish("CONCURRENT REPLACEMENT",in:root)
        check(try Data(contentsOf:style)==original,"existing user or generated nonempty style is never overwritten")
        let packed=try DoubleTapInference.packVault(root)
        check(packed.text.contains("hello :)") && packed.notes==1,"available style remains complete alongside knowledge")
        let staging=root.appendingPathComponent("staging")
        try fm.createDirectory(at:staging,withIntermediateDirectories:true)
        try "INVENTED STYLE".write(to:staging.appendingPathComponent(WritingStyle.fileName),atomically:true,encoding:.utf8)
        try WritingStyle.preserve(in:staging,from:root)
        check(try Data(contentsOf:staging.appendingPathComponent(WritingStyle.fileName))==original,"knowledge swap preserves the original user style")
        try fm.removeItem(at:staging)
        try fm.removeItem(at:style)
        try Data().write(to:style)
        try WritingStyle.publishIfNeeded("DO NOT REPLACE INTENTIONAL EMPTY FILE",in:root)
        check(try Data(contentsOf:style).isEmpty,"existing empty style is retained because user intent cannot be inferred")
        let empty=try DoubleTapInference.packVault(root)
        check(empty.notes==1 && empty.text.contains("Fixture knowledge"),"intentional empty style does not block drafting")
        try fm.removeItem(at:style)
        try String(repeating:"x",count:DoubleTapInference.vaultByteCeiling+1).write(to:style,atomically:true,encoding:.utf8)
        var refused=false
        do{_=try DoubleTapInference.packVault(root)}catch DoubleTapInference.Failure.writingStyleTooLarge{refused=true}
        check(refused,"oversized existing samples remain an explicit error rather than silent truncation")
        print("Optional writing style: \(checks) checks passed")
    }
}
'''
fixture=fixture.replace('// WRITING','\n'.join(member(writing,s)for s in('static func exists(','@MainActor static func publishIfNeeded(','static func publish(','static func preserve(')))
fixture=fixture.replace('// PACKING',member(inference,'struct PackedVault')+'\n'+member(inference,'static func packVault('))
with tempfile.TemporaryDirectory(prefix='sentient-optional-style-')as directory:
    path=Path(directory);(path/'main.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-parse-as-library',str(path/'main.swift'),'-o',str(path/'check')],check=True)
    scratch=path/'knowledge';scratch.mkdir()
    subprocess.run([str(path/'check'),str(scratch)],check=True)
