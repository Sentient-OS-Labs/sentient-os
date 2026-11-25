#!/usr/bin/env python3
"""Keep signing selection in xcconfig so Xcode UI edits cannot override it silently.

Doc: Sentient OS macOS/Updates/Documentation - Auto-Update (Sparkle) & Release Pipeline.md
"""

import json
from pathlib import Path
import subprocess
import sys


def check(root):
    project = root / "Sentient OS macOS.xcodeproj/project.pbxproj"
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(project)],
        check=True, capture_output=True, text=True,
    )
    signing_keys = {"DEVELOPMENT_TEAM", "CODE_SIGN_STYLE", "CODE_SIGN_IDENTITY"}
    for obj in json.loads(result.stdout)["objects"].values():
        if obj.get("isa") != "XCBuildConfiguration":
            continue
        for key in obj.get("buildSettings", {}):
            if key.split("[", 1)[0] in signing_keys:
                raise ValueError(
                    f"{obj.get('name', 'Build configuration')}: {key} overrides xcconfig. "
                    "Remove it from the project Build Settings; use Signing.xcconfig "
                    "or the gitignored Signing.local.xcconfig instead."
                )


if __name__ == "__main__":
    try:
        check(Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1])
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: Signing configuration: {error}")
