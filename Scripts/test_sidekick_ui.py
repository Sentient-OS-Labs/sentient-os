#!/usr/bin/env python3
"""Run the signed DEBUG app's isolated Home/notch rendering fixture, with no provider calls.

The existing app runner verifies the signature/capability and installs a fresh fixture suite.
This runner checks durable fixture events, exact draft retention and every PNG independently.
Screenshots contain only the app-owned synthetic windows, never the user's desktop.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile

sys.dont_write_bytecode = True
import test_sidekick_app as app

EXPECTED_IMAGES = {
    "01-overview-1100", "01b-overview-840", "01b-overview-840-notice", "01b-chat-840-notice", "01c-overview-wide", "02-transition-0ms", "02-transition-150ms", "02-transition-300ms",
    "02-transition-600ms", "03-conversation-1100", "04-selected-reply", "04a-floating-selection-reply", "05-history-search",
    "06-long-markdown", "07-conversation-840", "08-reduced-motion-transparency",
    "09-system-light-appearance", "10-system-dark-appearance", "11-pending-question",
    "12-notch-question", "13-notch-message", "13b-notch-empty-retry",
    "14-response-hover", "15-prompt-hover", "16-inline-activity", "01d-card-dismiss-hover",
    "17-settings-opening", "18-settings-open", "19-settings-closing", "20-home-after-settings",
    "21-settings-reduced-motion", "22-scroll-pull-40", "23-scroll-pull-90", "24-scroll-reversed-55", "25-scroll-settled",
    "26-knowledge-opening", "27-knowledge-open", "28-knowledge-closing", "29-home-after-knowledge", "30-knowledge-reduced-motion", "31-knowledge-vault-missing", "32-knowledge-vault-restored",
}
DRAFT = "Can you help me find a quiet hour tomorrow?"


def check_output(root: Path, receipt: dict) -> dict:
    manifest = app.read_json(root / "ui-manifest.json")
    state = app.snapshot(root)
    app.require(manifest.get("generation") == state["generation"] == receipt.get("generation"),
                "UI fixture changed or misreported conversation generation")
    baseline = manifest.get("baseline_sequence")
    app.require(isinstance(baseline, int) and baseline > 0, "Missing migrated baseline")
    events = [row["event"] for row in state["records"] if row["sequence"] > baseline]
    fixture_ids = set(manifest.get("fixture_tasks", []))
    app.require(len(fixture_ids) == 49 and {event["taskID"] for event in events} == fixture_ids,
                "Unexpected/missing fixture tasks")
    app.require(len(events) == 205 and all(event.get("source") == "ui_fixture" for event in events),
                "UI-only fixture unexpectedly started a real task or wrote unrelated data")
    app.require(not any(event["kind"] == "checkpoint" for event in events),
                "UI-only fixture should not create provider checkpoints")
    activity = [event for event in events if event["kind"] == "activity"]
    app.require(len(activity) == 8 and {event["id"] for event in activity} == {
        f"ui.activity.47.{step}.{status}" for step in range(4) for status in ["started", "completed"]
    } and all(event["activity"]["name"] in {"sentient_native.get_app_state", "sentient_native.click", "sentient_recovery.read_memory"} for event in activity),
                "Only the eight explicitly synthetic activity records may exist")
    for task in fixture_ids:
        terminal = [event for event in events if event["taskID"] == task and event["kind"] == "taskFinished"]
        app.require(len(terminal) == 1 and terminal[0].get("outcome") == "success",
                    "Fixture task lacks its single deterministic ending")
    question = next((event for event in events if event["id"] == "ui.question"), None)
    answer = next((event for event in events if event["id"] == "ui.question.answer"), None)
    app.require(question is not None and question.get("choices") == ["Protect the afternoon", "Keep it open"]
                and answer is not None and answer.get("text") == "Keep it open"
                and answer.get("reply", {}).get("messageID") == question["id"],
                "Real recovery answer is not linked to the fixture question")
    app.require(manifest.get("retained_draft") == DRAFT, "Draft changed across view transitions/rejected send")
    app.require(manifest.get("provider_calls") == 0, "Fixture reported provider use")
    app.require(next((event for event in events if event["id"] == manifest.get("markdown_message_id")), {}).get("text", "").find("```swift") >= 0,
                "Saved rich Markdown fixture is missing")
    images = manifest.get("snapshots", [])
    app.require(len(images) == len(EXPECTED_IMAGES) and {image.get("name") for image in images} == EXPECTED_IMAGES,
                "Missing UI states or animation frames")
    for image in images:
        file = root / image["file"]
        app.require(file.resolve().is_relative_to(root / "ui-snapshots") and not file.is_symlink(),
                    "Snapshot escaped its owned fixture directory")
        data = file.read_bytes()
        app.require(data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR", "Snapshot is not a PNG")
        width, height = struct.unpack(">II", data[16:24])
        app.require(width == image["width"] and height == image["height"]
                    and width >= image["logical_width"] and height >= image["logical_height"],
                    "Snapshot dimensions disagree with native view")
        app.require(len(data) == image["bytes"] and len(data) > 10_000
                    and hashlib.sha256(data).hexdigest() == image["sha256"], "Snapshot hash/size mismatch")
        app.require(image.get("capture_method") == "desktop_independent_own_window"
                    and image.get("window_id", 0) > 0 and image.get("owning_process_id", 0) > 0,
                    "Snapshot did not use the isolated own-window capture filter")
        app.require(image.get("nonblack_fraction", 0) > .035 and image.get("sampled_colors", 0) > 32,
                    "Snapshot lacks meaningful rendered pixels; native text checks alone are insufficient")
        if image["name"] in {"03-conversation-1100", "06-long-markdown", "13-notch-message"}:
            app.require(image.get("native_text_fragments", 0) > 0, "Snapshot contains no native message text views")
    native = app.read_json(root / "ui-snapshots/native-notch-question.json")
    app.require(native.get("capture_method") == "desktop_independent_own_window"
                and native.get("included_child_windows") is False
                and native.get("captures_audio") is False
                and native.get("captures_microphone") is False,
                "Native notch capture scope changed")
    native_png = (root / native["file"]).read_bytes()
    app.require(hashlib.sha256(native_png).hexdigest() == native.get("sha256")
                and len(native_png) == native.get("bytes"), "Native panel image mismatch")
    app.require(native["checks"] and all(native["checks"].values()), "Native panel lifecycle check failed")
    app.require(native["panel_frame"] == native["interrupted_frame"] == native["hidden_frame"],
                "Native panel resized during the morph")
    motion = app.read_json(root / "ui-motion.json")
    clip = root / "ui-snapshots" / motion["file"]
    app.require(motion.get("writer_completed") is True and clip.stat().st_size == motion.get("bytes")
                and motion.get("written_frames", 0) >= 20 and motion.get("postfirst_unavailable_frames", 0) == 0,
                "Actual motion recording is missing or incomplete")
    settings_motion = app.read_json(root / "ui-settings-motion.json")
    settings_clip = root / "ui-snapshots" / settings_motion["file"]
    app.require(settings_motion.get("writer_completed") is True
                and settings_clip.stat().st_size == settings_motion.get("bytes")
                and settings_motion.get("written_frames", 0) >= 20
                and settings_motion.get("postfirst_unavailable_frames", 0) == 0,
                "Settings motion recording is missing or incomplete")
    for name in ["scroll", "activity", "knowledge"]:
        recorded = app.read_json(root / f"ui-{name}-motion.json")
        movie = root / "ui-snapshots" / recorded["file"]
        app.require(movie.resolve().is_relative_to(root / "ui-snapshots")
                    and recorded.get("writer_completed") is True
                    and movie.stat().st_size == recorded.get("bytes")
                    and recorded.get("written_frames", 0) >= 20
                    and recorded.get("postfirst_unavailable_frames", 0) == 0,
                    f"{name} motion recording missing/incomplete")
    return {"ui_fixture_tasks": len(fixture_ids), "ui_fixture_events": len(events), "snapshots": len(images),
            "snapshot_directory": str(root / "ui-snapshots"), "retained_draft": True,
            "linked_recovery_answer": True, "provider_calls": 0}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Development-signed Debug app containing SidekickUILab")
    parser.add_argument("--artifacts", type=Path, default=Path(tempfile.gettempdir()) / "sentient-sidekick-ui")
    parser.add_argument("--runtime-root", type=Path, default=Path.home() / "Library/Application Support/SentientOS/Private Codex")
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--hold-seconds", "--hold", type=int, default=0, help="Keep the conversation window open for inspection (0–600 seconds); ui-hold-complete in the owned fixture ends inspection early")
    args = parser.parse_args()
    root = None
    try:
        app.require(0 <= args.hold_seconds <= 600, "--hold-seconds must be between 0 and 600 seconds")
        _, executable = app.resolve_app(args.app)
        artifacts = args.artifacts.expanduser().resolve()
        artifacts.mkdir(parents=True, exist_ok=True)
        root = Path(tempfile.mkdtemp(prefix="sentient-sidekick-app-ui-", dir=artifacts)).resolve()
        root.chmod(0o700)
        (root / app.MARKER).write_bytes(b"1\n")
        (root / "vault").mkdir(mode=0o700)
        # Synthetic graph content for the page reveal; never writes the real vault.
        (root / "vault" / "README.md").write_text("# UI fixture\n\nSynthetic notes for visual verification.\n\n[[Planning]] and [[Design]]\n")
        (root / "vault" / "Planning.md").write_text("# Planning\n\nA quiet afternoon. See [[Design]].\n")
        (root / "vault" / "Design.md").write_text("# Design\n\nBlack glass, light and space. See [[Planning]].\n")
        manifest = app.fixture(root, "chatgpt")
        manifest["ui_hold_seconds"] = args.hold_seconds
        app.save_json(root / "fixture.json", manifest)
        runtime = args.runtime_root.expanduser().resolve()
        print(f"UI fixture: {root}", flush=True)
        app.run_stage(executable, root, manifest, runtime, "seed", 60)
        app.require(not (root / "support/Sidekick/Conversation.sqlite").exists(), "Seed created the new store early")
        receipt = app.run_stage(executable, root, manifest, runtime, "ui", max(args.timeout, args.hold_seconds + 180))
        result = {"passed": True, "root": str(root), **check_output(root, receipt)}
        app.check_migration(root, app.snapshot(root), manifest)
        app.save_json(root / "ui-runner-result.json", result)
        print(json.dumps(result, indent=2))
        return 0
    except (app.AcceptanceFailure, OSError, ValueError) as error:
        print(f"FAIL: {error}", flush=True)
        if root:
            app.save_json(root / "ui-runner-result.json", {"passed": False, "root": str(root), "error": str(error)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
