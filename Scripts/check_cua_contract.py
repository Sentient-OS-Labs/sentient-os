#!/usr/bin/env python3
"""Build-time CUA pin/manual/catalog check; optionally compare a captured `list-tools` output."""

import argparse
import pathlib
import re
import sys


def check(root, tool_list=None):
    driver = (root / "Sentient OS macOS/Driver/CuaDriver.swift").read_text()
    manual = (root / "Sentient OS macOS/Driver/CuaDriverSkill.swift").read_text()

    def literal(source, name):
        values = re.findall(r'\bstatic let ' + name + r'\s*=\s*"([^"\n]+)"', source)
        if len(values) != 1:
            raise ValueError(f"expected exactly one literal {name}")
        return values[0]

    version = literal(driver, "version")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("driver version must identify one release")
    if literal(manual, "skillVersion") != version or literal(driver, "toolCatalogVersion") != version:
        raise ValueError("driver, inlined manual, and MCP catalog versions differ; re-curate and test the release together")
    if not re.fullmatch(r"[0-9a-f]{64}", literal(driver, "tarballSHA256")):
        raise ValueError("missing pinned release SHA-256")

    def names(name):
        match = re.search(r'\bstatic let ' + name + r'\s*=\s*\[(.*?)\]', driver, re.S)
        if not match:
            raise ValueError(f"missing {name} tool array")
        entries = re.findall(r'"([a-z][a-z0-9_]*)"', re.sub(r"//[^\n]*", "", match[1]))
        if not entries or len(entries) != len(set(entries)):
            raise ValueError(f"empty or duplicate tools in {name}")
        return set(entries)

    eyes, allowed, catalog = (names(name) for name in ("mcpTools", "enabledTools", "allMcpServedTools"))
    if eyes != {"get_window_state", "get_desktop_state", "zoom", "verify_state"}:
        raise ValueError("the MCP surface must remain the four native vision tools; actions share the CLI")
    if not eyes <= allowed <= catalog:
        raise ValueError("MCP eyes and CLI allowlist must belong to the captured driver catalog")
    if any(tool.startswith("browser_") or tool == "get_browser_state" for tool in allowed):
        raise ValueError("the typed browser route stays off: it attaches over Chrome's remote-debugging port, which raises a consent dialog on every connection; browsers are native windows (screenshot + accessibility tree)")
    if "--grant" in (root / "Sentient OS macOS/Driver/CuaDriverHost.swift").read_text():
        raise ValueError("the daemon must launch without a --grant; the existing-profile grant is what unlocks the typed browser route")
    if tool_list:
        live = set(re.findall(r"^([a-z][a-z0-9_]*):", tool_list.read_text(), re.M))
        if live != catalog:
            raise ValueError(f"catalog drift: added={sorted(live - catalog)}, removed={sorted(catalog - live)}")
    return version, len(catalog)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("--tool-list", type=pathlib.Path)
    args = parser.parse_args()
    try:
        version, count = check(args.root, args.tool_list)
        print(f"CUA {version}: manual and {count}-tool catalog agree; four MCP vision tools")
    except (ValueError, OSError) as error:
        print(f"error: CUA contract: {error}", file=sys.stderr)
        sys.exit(1)
