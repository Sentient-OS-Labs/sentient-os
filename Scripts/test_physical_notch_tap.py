#!/usr/bin/env python3
"""Deterministic light-plus-motion tap/wake checks. No hardware, UI, or real user defaults."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="sentient-physical-tap-") as folder:
    binary = Path(folder) / "checks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-o", str(binary),
                    str(root / "Sentient OS macOS/Notch Magic/PhysicalTapDetector.swift"),
                    str(root / "Sentient OS macOS/Notch Magic/NotchPreferences.swift"),
                    str(root / "Scripts/Fixtures/PhysicalTapTests.swift")], check=True)
    subprocess.run([str(binary)], check=True)

with tempfile.TemporaryDirectory(prefix="sentient-tap-calibration-") as folder:
    binary = Path(folder) / "checks"
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-o", str(binary),
                    str(root / "Sentient OS macOS/Notch Magic/PhysicalTapDetector.swift"),
                    str(root / "Sentient OS macOS/Notch Magic/NotchPreferences.swift"),
                    str(root / "Sentient OS macOS/Notch Magic/PhysicalTapCalibration.swift"),
                    str(root / "Scripts/Fixtures/PhysicalTapCalibrationTests.swift")], check=True)
    subprocess.run([str(binary)], check=True)
