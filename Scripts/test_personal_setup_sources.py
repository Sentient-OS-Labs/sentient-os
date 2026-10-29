#!/usr/bin/env python3
"""Exercise actual optional source/timing UI using only owned synthetic folders.

Requires a signed DEBUG app. Never opens real folders, connects accounts, starts analysis,
asks for protected-source access, installs wake helpers, or invokes a model.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import tempfile

sys.dont_write_bytecode = True
import test_sidekick_app as app


def check_first_launch_scope() -> dict:
    source = app.REPO / "Sentient OS macOS"
    onboarding = (source / "Views/Onboarding/OnboardingView.swift").read_text()
    state = (source / "App/AppState.swift").read_text()
    # Comments describe older flows in a few files; only executable declarations are checked.
    code = re.sub(r"//[^\n]*", "", onboarding)
    state_code = re.sub(r"//[^\n]*", "", state)
    checks = {
        "introduction_contains_film_and_model": "OnboardingFilmView(" in code and "OnboardingFrontierModelView(" in code,
        "personal_sources_not_in_required_introduction": "OnboardingReadyView(" not in code and "OnboardingPermissionsView(" not in code,
        "no_implicit_notification_request": all(token not in code + state_code for token in ["Notify.ask(", ".requestAuthorization("]),
    }
    app.require(all(checks.values()), "First-launch scope changed; review source/notification admission")
    return checks


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, default=Path(tempfile.gettempdir()) / "sentient-personal-sources")
    parser.add_argument("--runtime-root", type=Path,
                        default=Path.home() / "Library/Application Support/SentientOS/Private Codex")
    args = parser.parse_args()
    root = None
    try:
        scope_checks = check_first_launch_scope()
        _, executable = app.resolve_app(args.app)
        artifacts = args.artifacts.expanduser().resolve()
        artifacts.mkdir(parents=True, exist_ok=True)
        root = Path(tempfile.mkdtemp(prefix="sentient-sidekick-app-sources-", dir=artifacts)).resolve()
        root.chmod(0o700)
        (root / app.MARKER).write_bytes(b"1\n")
        (root / "vault").mkdir(mode=0o700)
        fixture = app.fixture(root, "chatgpt")
        runtime = args.runtime_root.expanduser().resolve()
        print(f"Personal sources fixture: {root}", flush=True)
        app.run_stage(executable, root, fixture, runtime, "seed", 60)
        receipt = app.run_stage(executable, root, fixture, runtime, "ui-personal-sources", 90)
        manifest = app.read_json(root / "personal-sources-manifest.json")
        captures = manifest.get("captures", [])
        app.require(manifest.get("completed") is True and len(captures) == 8, "Incomplete source/timing UI fixture")
        app.require(manifest.get("callbacks") == ["now", "now"]
                    and manifest.get("callbacks_after_sheet_dismissal") == [True, True], "Timing callback preceded native dismissal")
        app.require(manifest.get("provider_calls") == 0 and manifest.get("wake_setup_requests") == 0
                    and manifest.get("wake_refresh_uses_fixture") is True and manifest.get("wake_refresh_requests", 0) > 0,
                    "Fixture unexpectedly invoked external work")
        selections = [Path(value).resolve() for value in manifest.get("selected_roots", [])]
        app.require(len(selections) == 3 and all(path.parent == root / "source-fixtures" and path.is_dir() for path in selections),
                    "Source selection escaped owned fixtures")
        app.require(manifest.get("capture_scope") == "current_process_windows_only", "Unexpected screenshot scope")
        for capture in captures:
            path = (root / capture["file"]).resolve()
            app.require(path.parent == root / "polish-snapshots", "Capture escaped the owned fixture")
            app.require(path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
                        and path.stat().st_size > 4096, "Missing or empty UI image")
        result = {"passed": True, "root": str(root), "checks": len(receipt["checks"]), "scope_checks": scope_checks,
                  "captures": [str(root / item["file"]) for item in captures], "provider_calls": 0}
        app.save_json(root / "personal-sources-runner-result.json", result)
        print(json.dumps(result, indent=2))
        return 0
    except (app.AcceptanceFailure, OSError, ValueError) as error:
        print(f"FAIL: {error}", flush=True)
        if root:
            app.save_json(root / "personal-sources-runner-result.json",
                          {"passed": False, "root": str(root), "error": str(error)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
