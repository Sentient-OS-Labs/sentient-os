#!/usr/bin/env python3
"""Test native work-window identity. --live also exercises two disposable AppKit windows."""
from pathlib import Path
import argparse,subprocess,tempfile,time
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--live',action='store_true');args=p.parse_args()
with tempfile.TemporaryDirectory(prefix='sentient-work-window-') as d:
 work=Path(d);test=work/'check'
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(root/'Sentient OS macOS/Notch Magic/SidekickWorkWindow.swift'),str(root/'Scripts/Fixtures/WorkWindowTests.swift'),'-o',str(test)],check=True)
 subprocess.run([str(test)],check=True,timeout=15)
 if args.live:
  fixture=work/'windows'
  subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'Scripts/Fixtures/WorkWindowFixture.swift'),'-o',str(fixture)],check=True)
  child=subprocess.Popen([str(fixture)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  try:
   time.sleep(1)
   subprocess.run([str(test),str(child.pid)],check=True,timeout=20)
  finally:
   child.terminate();child.wait(timeout=5)
