#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p 'build/Lid Sensor Lab.app/Contents/MacOS'
xcrun swiftc -swift-version 5 -O -parse-as-library Sensors.swift ALSFrame.swift MotionFrame.swift Experiment.swift App.swift -framework AppKit -framework SwiftUI -framework IOKit -o 'build/Lid Sensor Lab.app/Contents/MacOS/LidSensorLab'
cat > 'build/Lid Sensor Lab.app/Contents/Info.plist' <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>LidSensorLab</string><key>CFBundleIdentifier</key><string>ai.sentient.lid-sensor-lab</string><key>CFBundleName</key><string>Lid Sensor Lab</string><key>CFBundlePackageType</key><string>APPL</string><key>NSHighResolutionCapable</key><true/><key>LSMinimumSystemVersion</key><string>14.0</string></dict></plist>
PLIST
codesign --force --sign - 'build/Lid Sensor Lab.app'
