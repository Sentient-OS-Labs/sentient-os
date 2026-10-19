"""Locate platform Swift macros for standalone UI fixtures using the selected Xcode."""
from pathlib import Path
import subprocess


def platform_plugin_flags():
    platform = Path(subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], text=True).strip())
    plugins = platform / "Developer/usr/lib/swift/host/plugins"
    return ["-plugin-path", str(plugins)] if plugins.is_dir() else []
