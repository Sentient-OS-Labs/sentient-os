#!/usr/bin/env python3
"""Render the production notch illustration at fixed gesture poses, without launching the app."""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Sentient OS macOS'

def declaration(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
row = (APP / 'Notch Magic/NotchQuickActionRow.swift').read_text()
metrics = (APP / 'Notch Magic/NotchView.swift').read_text()
fixture = '''
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
struct NotchMetrics {
    var hardwareNotch: CGSize?
    var cameraCenterOffset: CGFloat = 0
    var baseWidth: CGFloat = 200
    // SENSOR
}
// FINGER
@main enum Render {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func render(_ time: Double, scale: CGFloat) -> CGImage {
            let content = OnboardingNotchTapIllustration(presentationTime: time)
                .frame(width: 600, height: 280).padding(32)
                .background(.black).preferredColorScheme(.dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = scale
            guard let image = renderer.cgImage else { fatalError("Illustration did not render") }
            return image
        }
        for (name, time) in [("approach", 0.9), ("contact", 1.5), ("lift", 2.2)] {
            guard let data = NSBitmapImageRep(cgImage: render(time, scale: 2)).representation(using: .png, properties: [:]) else {
                fatalError("PNG encoding failed")
            }
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        let count = Int((OnboardingNotchTapIllustration.colorCycleDuration * 25).rounded())
        guard let gif = CGImageDestinationCreateWithURL(directory.appendingPathComponent("tap-loop.gif") as CFURL,
            UTType.gif.identifier as CFString, count, nil) else { fatalError("GIF output unavailable") }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<count {
            autoreleasepool {
                CGImageDestinationAddImage(gif, render(Double(index) / 25, scale: 1),
                    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 25,
                     kCGImagePropertyGIFUnclampedDelayTime: 1.0 / 25]] as CFDictionary)
            }
        }
        precondition(CGImageDestinationFinalize(gif), "GIF encoding failed")
    }
}
'''.replace('// SENSOR', declaration(metrics, 'var lightSensorOffset:'))
fixture = fixture.replace('// FINGER', declaration(row, 'struct TapLocationFinger:'))
with tempfile.TemporaryDirectory(prefix='sentient-notch-illustration-') as temporary:
    temp = Path(temporary)
    (temp / 'Render.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
        '-default-isolation', 'MainActor', str(APP / 'Notch Magic/NotchShape.swift'),
        str(APP / 'Views/Onboarding/OnboardingNotchTapIllustration.swift'), str(temp / 'Render.swift'),
        '-o', str(temp / 'render')], check=True)
    subprocess.run([str(temp / 'render'), str(output)], check=True)
print(output)
