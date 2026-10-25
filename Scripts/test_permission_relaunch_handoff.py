#!/usr/bin/env python3
"""Real owned subprocess handoff, with a synthetic launch callback: never opens an app.
Tests parent lifetime, commit/cancel, bounded expiry, failed preparation and launch receipts.
"""
from pathlib import Path
import json
import subprocess
import tempfile
import time

APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'
source=(APP/'System/PermissionRelaunchHandoff.swift').read_text()
source += '\nextension PermissionRelaunchHandoff.Ticket { var fixtureDirectory: URL { directory } }\n'
RUNNER=r'''
import Foundation
import Darwin
@main enum Runner {
    @MainActor static func main() async throws {
        let args=CommandLine.arguments
        if args.dropFirst().first == PermissionRelaunchHandoff.argument {
            let directory=URL(fileURLWithPath:args[3]), root=directory.deletingLastPathComponent()
            let scenario=(try? String(contentsOf:root.appendingPathComponent("scenario"),encoding:.utf8)) ?? ""
            let status=PermissionRelaunchHandoff.run(arguments:args,timeout:scenario == "expired" ? 0.25 : 3) {
                let value=scenario == "launch-failed" ? "failed" : "launched"
                try? Data(value.utf8).write(to:root.appendingPathComponent("launch"),options:.atomic)
                return scenario == "launch-failed" ? 1 : 0
            }
            exit(status)
        }
        let scenario=args[1],root=URL(fileURLWithPath:args[2],isDirectory:true)
        if scenario == "prepare-failed" {
            do { _=try await PermissionRelaunchHandoff.prepare(executable:root.appendingPathComponent("missing"),temporaryRoot:root);fatalError("Launched missing helper") }
            catch { try Data("expected".utf8).write(to:root.appendingPathComponent("failure"));return }
        }
        let ticket=try await PermissionRelaunchHandoff.prepare(temporaryRoot:root)
        try Data(ticket.fixtureDirectory.path.utf8).write(to:root.appendingPathComponent("directory"))
        if scenario != "uncommitted" {try ticket.commit()}
        if scenario == "cancelled" {ticket.cancel()}
        try await Task.sleep(for:scenario == "expired" ? .milliseconds(500) : .milliseconds(150))
        precondition(!FileManager.default.fileExists(atPath:root.appendingPathComponent("launch").path),"Second app launched before old parent exited")
        try Data("held".utf8).write(to:root.appendingPathComponent("held-until-exit"))
        exit(0)
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-relaunch-contract-') as directory:
 root=Path(directory).resolve()
 (root/'Handoff.swift').write_text(source)
 (root/'Runner.swift').write_text(RUNNER)
 binary=root/'runner'
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'Handoff.swift'),str(root/'Runner.swift'),'-o',str(binary)],check=True,timeout=60)
 checks=0
 for scenario in ['committed','uncommitted','cancelled','expired','prepare-failed','launch-failed']:
  case=root/scenario;case.mkdir(mode=0o700)
  (case/'scenario').write_text(scenario)
  subprocess.run([str(binary),scenario,str(case)],check=True,timeout=10)
  time.sleep(0.25)
  if scenario == 'prepare-failed':
   assert (case/'failure').read_text()=='expected';checks+=1;continue
  assert (case/'held-until-exit').read_text()=='held';checks+=1
  if scenario in ['committed','launch-failed']:
   assert (case/'launch').read_text()==('failed' if scenario=='launch-failed' else 'launched');checks+=1
  else:
   assert not (case/'launch').exists();checks+=1
  handoff=Path((case/'directory').read_text())
  if scenario=='launch-failed':
   assert (handoff/'result').read_text()=='launch_failed\n';checks+=1
  else:
   assert not handoff.exists();checks+=1
 print(f'PASS {checks} real subprocess relaunch handoff checks; no app launched')
