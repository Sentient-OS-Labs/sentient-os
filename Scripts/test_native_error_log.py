#!/usr/bin/env python3
"""Verify exact local native failure evidence, rotation and restrictive permissions."""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'
SOURCE = r'''
import Foundation
@main struct Tests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let text = String(repeating: "Exact unmodified error α\n", count: 500) + "TAIL_SENTINEL"
        let value: [String: Any] = ["isError":true, "content":[["type":"text", "text":text]], "details":["nativeCode":123]]
        let failure = NativeComputerUseFailure.classify(value)
        let raw = try JSONSerialization.jsonObject(with: failure.rawError!) as! NSDictionary
        precondition(raw.isEqual(to: value), "full raw error survives classification")
        precondition(!failure.fields.description.contains("TAIL_SENTINEL"), "remote metadata excludes raw content")
        let log = NativeComputerUseErrorLog(directory: root, maximumBytes: 100)
        log.append(tool:"test_first",failure:failure); log.flush()
        let file = root.appendingPathComponent("errors.jsonl")
        let entry = try JSONSerialization.jsonObject(with: Data(contentsOf:file)) as! [String:Any]
        precondition((entry["raw_error"] as! NSDictionary).isEqual(to:value), "raw error logged without truncation")
        let perms = try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as! NSNumber
        precondition(perms.intValue == 0o600)
        let directoryPerms = try FileManager.default.attributesOfItem(atPath:root.path)[.posixPermissions] as! NSNumber
        precondition(directoryPerms.intValue == 0o700)
        log.append(tool:"test_second",failure:failure); log.flush()
        let previous = try JSONSerialization.jsonObject(with: Data(contentsOf:root.appendingPathComponent("errors.previous.jsonl"))) as! [String:Any]
        let current = try JSONSerialization.jsonObject(with: Data(contentsOf:file)) as! [String:Any]
        precondition(previous["tool"] as? String == "test_first" && current["tool"] as? String == "test_second")
        let unavailable = NativeComputerUseErrorLog(directory:file)
        unavailable.append(tool:"no_disk",failure:failure); unavailable.flush()
        print("PASS raw native error roundtrip, no truncation, local-only metadata, rotation, permissions and write failure isolation")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-native-error-log-') as directory:
    root = Path(directory)
    source = root/'Tests.swift'; source.write_text(SOURCE)
    binary = root/'tests'
    subprocess.run(['xcrun','swiftc','-parse-as-library',str(source),str(APP/'Diagnostics/NativeComputerUseFailure.swift'),str(APP/'Diagnostics/NativeComputerUseErrorLog.swift'),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(root/'logs')],check=True)
