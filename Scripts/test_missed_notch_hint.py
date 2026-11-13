#!/usr/bin/env python3
"""Test conservative missed-tap recognition without opening sensors or changing defaults."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='sentient-missed-tap-') as folder:
 binary=Path(folder)/'checks'
 subprocess.run(['xcrun','swiftc','-O','-parse-as-library',str(root/'Sentient OS macOS/Notch Magic/PhysicalMissedTapDetector.swift'),str(root/'Scripts/Fixtures/MissedTapHintTests.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
