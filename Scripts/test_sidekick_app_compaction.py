#!/usr/bin/env python3
"""Verify automatic compaction through actual signed-app prompt submissions.

Only previously successful, runner-owned fixture data is cloned. Authentication is never
copied. The parent runner's signature, DEBUG-capability, stage, process and preferences
checks remain authoritative. --prepare-only performs no app/provider launch.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
import test_sidekick_app as app

DATE_REFERENCE_OFFSET = 978_307_200
USER_EDIT = "USER-EDIT-KEEP-519"
ROLES = {"warmup_1", "warmup_2", "warmup_3", "held_question", "followup"}
PREFERENCE_KEYS = {"hasCompletedOnboarding", "computerUse.micSpeechOffered", "computerUse.everReady",
                   "computerUse.nativeEverReady", "model.backend", "plan.kbOnly", "sidekick.context",
                   "sidekick.memoryMigrated"}


def marked_root(path: Path) -> tuple[Path, dict]:
    root = path.expanduser().resolve()
    app.require(root.name.startswith("sentient-sidekick-app-") and root.stat().st_uid == os.getuid(),
                "Source/prepared root is not an owned acceptance fixture")
    app.require((root / app.MARKER).read_bytes() == b"1\n", "Acceptance root marker is invalid")
    manifest = app.read_json(root / "fixture.json")
    nonce = manifest.get("nonce")
    app.require(isinstance(nonce, str) and str(uuid.UUID(nonce)) == nonce
                and manifest.get("suite") == "ai.sentient.sidekick-app." + nonce
                and manifest.get("provider") in {"chatgpt", "claude"}, "Invalid fixture manifest identity")
    return root, manifest


def readonly(path: Path) -> sqlite3.Connection:
    app.require(path.is_file() and not path.is_symlink(), "Fixture database must be a real file")
    connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=5)
    connection.execute("PRAGMA query_only=ON")
    return connection


def summaries(root: Path) -> list[dict]:
    connection = readonly(root / "support/Sidekick/Conversation.sqlite")
    try:
        generation = connection.execute("SELECT generation FROM state WHERE singleton=1").fetchone()[0]
        return [{"generation": generation, "from_sequence": row[0], "through_sequence": row[1],
                 "text": row[2], "created_at_unix": row[3]}
                for row in connection.execute("SELECT from_sequence, through_sequence, text, created_at FROM summaries ORDER BY from_sequence")]
    finally:
        connection.close()


def raw_event_digest(root: Path, through: int) -> str:
    connection = readonly(root / "support/Sidekick/Conversation.sqlite")
    digest = hashlib.sha256()
    try:
        for sequence, payload in connection.execute("SELECT sequence, payload FROM events WHERE sequence <= ? ORDER BY sequence", (through,)):
            data = bytes(payload)
            digest.update(int(sequence).to_bytes(8, "big"))
            digest.update(len(data).to_bytes(8, "big"))
            digest.update(data)
        return digest.hexdigest()
    finally:
        connection.close()


def fingerprint(root: Path) -> dict:
    state = app.snapshot(root)
    through = state["records"][-1]["sequence"] if state["records"] else 0
    memory = root / "support/Sidekick/SidekickMemory.md"
    app.require(memory.is_file() and not memory.is_symlink(), "Fixture memory is unavailable")
    return {"state": state, "summaries": summaries(root), "latest_sequence": through,
            "raw_events_sha256": raw_event_digest(root, through),
            "memory_sha256": hashlib.sha256(memory.read_bytes()).hexdigest()}


def safe_copy(source: Path, destination: Path) -> None:
    app.require(source.is_file() and not source.is_symlink(), f"Fixture source is not a regular file: {source.name}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(0o600)


def clone_preferences(source_manifest: dict, target_manifest: dict, root: Path, memory: bytes) -> None:
    # Both identities were validated. Export only the source FIXTURE suite, never the app's
    # production domain. Import a small whitelist; diagnostic/rate-limit caches are not needed.
    exported = subprocess.run(["/usr/bin/defaults", "export", source_manifest["suite"], "-"],
                              capture_output=True, timeout=5)
    app.require(exported.returncode == 0, "Could not read source fixture preferences")
    source = plistlib.loads(exported.stdout)
    app.require(source.get("lab.fixture.nonce") == source_manifest["nonce"], "Source fixture preferences have wrong nonce")
    app.require(source.get("sidekick.context") == memory.decode() and source.get("sidekick.memoryMigrated") is True,
                "Source fixture memory mirror is inconsistent")
    app.require(source.get("model.backend") == source_manifest["provider"]
                and source.get("hasCompletedOnboarding") is True, "Source is not a completed app fixture")
    values = {key: source[key] for key in PREFERENCE_KEYS if key in source}
    app.require(all(isinstance(value, (bool, str)) for value in values.values()), "Unexpected preference type in fixture whitelist")
    values["lab.fixture.nonce"] = target_manifest["nonce"]
    payload = root / "imported-fixture-preferences.plist"
    payload.write_bytes(plistlib.dumps(values, fmt=plistlib.FMT_BINARY))
    payload.chmod(0o600)
    imported = subprocess.run(["/usr/bin/defaults", "import", target_manifest["suite"], str(payload)],
                              capture_output=True, timeout=5)
    app.require(imported.returncode == 0, "Could not import new isolated fixture preferences")
    app.preferences(target_manifest, expected=lambda current: current.get("lab.fixture.nonce") == target_manifest["nonce"]
                    and current.get("sidekick.context") == memory.decode()
                    and current.get("sidekick.memoryMigrated") is True)


def prepare(source_path: Path, artifacts: Path) -> tuple[Path, dict]:
    source, original_manifest = marked_root(source_path)
    original = fingerprint(source)
    app.require(len(original["state"]["tasks"]) == 13 and not original["summaries"],
                "Source must contain the successful 13-task acceptance history and no summary")
    app.require(all(row[3] is not None for row in original["state"]["tasks"]), "Source fixture has unfinished tasks")
    oracle = app.read_json(source / "exercise-receipt.json")
    app.require(oracle.get("passed") is True and oracle.get("provider") == original_manifest["provider"]
                and oracle.get("suite") == original_manifest["suite"], "Source exercise oracle was not successful")
    reopened = app.read_json(source / "reopen-receipt.json")
    app.require(reopened.get("passed") is True and reopened.get("suite") == original_manifest["suite"],
                "Source fixture did not pass relaunch")
    app.require(app.read_json(source / "runner-result.json").get("passed") is True, "Source lacks independent passing acceptance proof")
    memory = (source / "support/Sidekick/SidekickMemory.md").read_bytes()
    app.require(USER_EDIT.encode() in memory, "Source lacks the verified user-edited memory fixture")
    root = Path(tempfile.mkdtemp(prefix=f"sentient-sidekick-app-compaction-{original_manifest['provider']}-", dir=artifacts)).resolve()
    root.chmod(0o700)
    (root / app.MARKER).write_bytes(b"1\n")
    nonce = str(uuid.uuid4())
    manifest = {**original_manifest, "nonce": nonce, "suite": "ai.sentient.sidekick-app." + nonce,
                "source_fixture_root": str(source), "compaction_fixture": True}
    app.save_json(root / "fixture.json", manifest)
    (root / "suite-name.txt").write_text(manifest["suite"] + "\n")
    for name in ["migration-fixture.json"]:
        safe_copy(source / name, root / name)
    safe_copy(source / "exercise-receipt.json", root / "source-exercise-receipt.json")
    safe_copy(source / "support/Sidekick/SidekickMemory.md", root / "support/Sidekick/SidekickMemory.md")
    source_vault = source / "vault"
    app.require(source_vault.is_dir() and not source_vault.is_symlink(), "Source vault is not an isolated directory")
    app.require(not any(path.is_symlink() for path in source_vault.rglob("*")), "Fixture vault contains an external symlink")
    shutil.copytree(source_vault, root / "vault")
    source_db = readonly(source / "support/Sidekick/Conversation.sqlite")
    destination = sqlite3.connect(root / "support/Sidekick/Conversation.sqlite")
    try:
        source_db.backup(destination)
    finally:
        destination.close(); source_db.close()
    (root / "support/Sidekick/Conversation.sqlite").chmod(0o600)
    clone_preferences(original_manifest, manifest, root, memory)
    copied = fingerprint(root)
    app.require(copied == original, "SQLite backup/memory copy did not preserve source fixture exactly")
    app.require(fingerprint(source) == original, "Preparing fixture changed the original proof profile")
    baseline = {"source_root": str(source), **original}
    app.save_json(root / "source-baseline.json", baseline)
    app.save_json(root / "prepare-result.json", {"passed": True, "provider": manifest["provider"], "root": str(root),
                  "source_root": str(source), "tasks": 13, "summaries": 0,
                  "original_semantic_sha256": original["state"]["semantic_sha256"]})
    print(f"[{manifest['provider']}] prepared isolated compaction clone: {root}", flush=True)
    return root, manifest


def check_result(root: Path, receipt: dict) -> dict:
    baseline = app.read_json(root / "source-baseline.json")
    state = app.snapshot(root)
    stored = summaries(root)
    original_records = baseline["state"]["records"]
    app.require(state["generation"] == baseline["state"]["generation"], "Compaction changed conversation generation")
    app.require(state["records"][:len(original_records)] == original_records, "Compaction changed original source records")
    app.require(raw_event_digest(root, baseline["latest_sequence"]) == baseline["raw_events_sha256"],
                "Original SQLite event payload bytes changed")
    memory = (root / "support/Sidekick/SidekickMemory.md").read_bytes()
    app.require(hashlib.sha256(memory).hexdigest() == baseline["memory_sha256"], "Automatic compaction or prompts changed memory")
    tasks = receipt.get("tasks", [])
    roles = {task.get("role"): task for task in tasks}
    app.require(len(tasks) == 5 and set(roles) == ROLES, "Compaction did not exercise all five real prompts")
    original_ids = {row[0] for row in baseline["state"]["tasks"]}
    actual_ids = {row[0] for row in state["tasks"]}
    new_ids = {str(uuid.UUID(task["task_id"])).upper() for task in tasks}
    app.require(len(actual_ids) == 18 and actual_ids - original_ids == new_ids and len(new_ids) == 5,
                "Unexpected, duplicate or missing actual task executions")
    events = [row["event"] for row in state["records"]]
    by_task: dict[str, list[dict]] = {}
    for event in events:
        by_task.setdefault(event["taskID"], []).append(event)
    answers = {}
    for role, task in roles.items():
        observed = by_task[str(uuid.UUID(task["task_id"])).upper()]
        requests = [event for event in observed if event["kind"] == "userMessage"]
        endings = [event for event in observed if event["kind"] == "taskFinished"]
        explicit = [event for event in observed if event["kind"] == "assistantMessage"
                    and event.get("messageKind") == "answer" and not event["id"].startswith("fallback:")]
        app.require(len(requests) == 1 and requests[0]["text"] == task["request"]
                    and requests[0].get("source") == "promptBar", f"Task bypassed actual prompt entry: {role}")
        app.require(task.get("expected_outcome") == "success" and len(endings) == 1
                    and endings[0].get("outcome") == "success" and explicit, f"Task did not explicitly answer and finish once: {role}")
        app.require(not any(event["id"].startswith("fallback:") for event in observed), f"Task used fallback message delivery: {role}")
        answers[role] = "\n".join(event["text"] for event in explicit)
    held = by_task[str(uuid.UUID(roles["held_question"]["task_id"])).upper()]
    actual_answers = [event for event in held if event["kind"] == "answer"]
    app.require(roles["held_question"].get("expected_answer") == "Continue" and len(actual_answers) == 1
                and actual_answers[0]["text"] == "Continue", "Held task lacks the actual Continue answer")
    source_question = next((event for event in held if event["kind"] == "question"
                            and event["id"] == actual_answers[0].get("reply", {}).get("messageID")), None)
    app.require(source_question is not None and "Continue" in source_question.get("choices", []), "Continue is not linked to the real held question")
    app.require(stored and all(summary["text"].strip() and len(summary["text"].encode()) <= 10_000 for summary in stored),
                "No valid automatic summary was installed")
    expected_from = 1
    task_bounds = {row[0]: (row[1], row[3]) for row in state["tasks"]}
    for summary in stored:
        start, through = summary["from_sequence"], summary["through_sequence"]
        app.require(start == expected_from and through >= start, "Summary prefixes have a gap or overlap")
        covered = [row["event"] for row in state["records"] if start <= row["sequence"] <= through]
        app.require(covered and covered[-1]["kind"] == "taskFinished", "Summary ends inside a task")
        for first, last in task_bounds.values():
            if first <= through:
                app.require(last is not None and last <= through, "Summary covers an unfinished/split task")
        references = [event["id"] for event in covered if event["kind"] not in {"activity", "taskStarted"}]
        app.require(any(identifier in summary["text"] for identifier in references), "Summary lacks an exact original message reference")
        # These legacy fixtures contain outcomes but no confirming action results. Require
        # an uncertainty cue; missing old answers must not become evidence of no effects.
        if any(event.get("outcome") in {"failed", "stopped"} for event in covered):
            uncertainty = ["unknown", "unconfirmed", "not confirmed", "not verified", "no confirming",
                           "does not establish", "doesn't establish", "cannot confirm", "could not confirm",
                           "may have", "might have"]
            app.require(any(cue in summary["text"].lower() for cue in uncertainty),
                        "Summary lost uncertainty about failed/stopped fixture work")
        # This fixture's eligible prefix is entirely migrated legacy data. It must use
        # deterministic extraction, not model-authored conclusions about missing evidence.
        app.require(summary["text"].startswith("IMPORTED LEGACY HISTORY — RECORDED REPORTS ONLY\n")
                    and "\nRECORDS:\n" in summary["text"], "Sparse legacy history was sent through inference")
        ledger = json.loads(summary["text"].split("\nRECORDS:\n", 1)[1])
        app.require(isinstance(ledger, list) and len(ledger) == len(covered),
                    "Legacy extraction omitted or invented records")
        for actual, original in zip(ledger, covered):
            app.require(actual.get("id") == original["id"] and actual.get("task") == original["taskID"]
                        and actual.get("kind") == original["kind"] and actual.get("outcome") == original.get("outcome")
                        and actual.get("text") == original["text"] and actual.get("truncated") is False,
                        "Legacy extraction changed literal evidence or invented an action outcome")
        app.require(not any(row["event"]["id"] in summary["text"] for row in state["records"] if row["sequence"] > through),
                    "Summary references a future event outside its source prefix")
        expected_from = through + 1
    # Independent completed-task intervals, rather than reusing the store's boundary query.
    latest_sequence = {task_id: max(row["sequence"] for row in state["records"] if row["event"]["taskID"] == task_id)
                       for task_id in actual_ids}
    retained = sorted(actual_ids, key=latest_sequence.get, reverse=True)[:15]
    earliest_protected = min(task_bounds[task_id][0] for task_id in retained)
    eligible_ends = [last for first, last in task_bounds.values() if last is not None and last < earliest_protected]
    app.require(stored[-1]["through_sequence"] == max(eligible_ends), "Automatic summaries did not catch up to the completed prefix")
    first_receipt = receipt.get("first_summary", {})
    first = stored[0]
    app.require(app.REFERENCE in first["text"],
                "First automatic summary lost the original project codename")
    for key in ["generation", "from_sequence", "through_sequence", "text"]:
        app.require(first_receipt.get(key) == first[key], "First observed summary does not match SQLite")
    app.require(abs(float(first_receipt.get("created_at_unix", -1)) - first["created_at_unix"]) < .01,
                "First summary timestamp differs from SQLite")
    held_start = min(event["createdAt"] for event in held if event["kind"] == "taskStarted") + DATE_REFERENCE_OFFSET
    held_end = max(event["createdAt"] for event in held if event["kind"] == "taskFinished") + DATE_REFERENCE_OFFSET
    answered_at = actual_answers[0]["createdAt"] + DATE_REFERENCE_OFFSET
    app.require(held_start <= first["created_at_unix"] <= answered_at <= held_end,
                "First automatic summary was not installed during the foreground held task")
    observed_at = receipt.get("first_summary_observed_at_unix", -1)
    app.require(first["created_at_unix"] <= observed_at <= answered_at,
                "Summary observation happened outside the actual unanswered foreground interval")
    app.require(receipt.get("summary_observed_while_running") is True and receipt.get("summary_observed_while_waiting") is True,
                "Summary was not observed during the actual active question wait")
    context = receipt.get("followup_context")
    app.require(isinstance(context, str) and "{" in context, "No actual following-task context was captured")
    body = json.loads(context[context.index("{"):])
    segments = body.get("olderSegments", [])
    app.require(segments, "The next actual prompt did not receive accepted summary context")
    for segment in segments:
        match = next((summary for summary in stored if summary["from_sequence"] == segment.get("fromSequence")
                      and summary["through_sequence"] == segment.get("throughSequence")), None)
        app.require(match is not None and segment.get("truncated") is False and segment.get("summary") == match["text"],
                    "Following-task summary context differs from the accepted stored segment")
    oracle = app.read_json(root / "source-exercise-receipt.json")
    hidden = oracle["observed_action"]["revealed_token"]
    for token in [hidden, app.REFERENCE, USER_EDIT]:
        app.require(token not in roles["followup"]["request"], "Continuation answer leaked into the new prompt")
        app.require(token in answers["followup"], "Following-task answer lost original native/summary/memory context")
    shell_names = {"command_execution", "local_shell_call", "bash", "exec_command", "shell_command", "write_stdin"}
    follow_events = by_task[str(uuid.UUID(roles["followup"]["task_id"])).upper()]
    for event in follow_events:
        if event["kind"] == "activity":
            name = event.get("activity", {}).get("name", "")
            leaf = name.replace("__", ".").rsplit(".", 1)[-1].lower()
            app.require("sentient_native" not in name and "node_repl" not in name and leaf not in shell_names,
                        "Following-task recall came from new native/script inspection instead of saved context")
    return {"passed": True, "task_count": len(actual_ids), "new_tasks": 5, "summary_count": len(stored),
            "summary_through": stored[-1]["through_sequence"], "foreground_overlap_verified": True,
            "context_matches_accepted_summary": True, "original_raw_events_unchanged": True,
            "memory_unchanged": True, "state": state, "summaries": stored}


def execute(root: Path, manifest: dict, executable: Path, runtime: Path, timeout: int) -> dict:
    baseline = app.read_json(root / "source-baseline.json")
    result: dict = {"passed": False, "root": str(root), "provider": manifest["provider"]}
    source = Path(baseline["source_root"])
    try:
        receipt = app.run_stage(executable, root, manifest, runtime, "compaction", timeout)
        verified = check_result(root, receipt)
        app.save_json(root / "independent-compaction-snapshot.json", verified)
        before = fingerprint(root)
        app.run_stage(executable, root, manifest, runtime, "compaction_reopen", 120)
        after = fingerprint(root)
        app.require(after == before, "Reopen repeated work or changed history, summaries, generation or memory")
        current_source = fingerprint(source)
        app.require(current_source["state"]["semantic_sha256"] == baseline["state"]["semantic_sha256"]
                    and all(current_source[key] == baseline[key] for key in ["summaries", "latest_sequence", "raw_events_sha256", "memory_sha256"]),
                    "Original acceptance proof profile changed during clone acceptance")
        result.update({key: value for key, value in verified.items() if key not in {"state", "summaries"}})
        result["relaunch_idempotent"] = True
        result["source_profile_unchanged"] = True
    except Exception as error:
        result["failure"] = str(error)
        app.save_json(root / "compaction-runner-result.json", result)
        raise app.AcceptanceFailure(f"{manifest['provider']}: {error}; retained artifacts: {root}") from None
    app.save_json(root / "compaction-runner-result.json", result)
    print(f"[{manifest['provider']}] PASS: actual automatic summaries, foreground overlap, context reuse and relaunch independently verified", flush=True)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Development-signed Debug app (required unless --prepare-only)")
    sources = parser.add_mutually_exclusive_group(required=True)
    sources.add_argument("--source-root", type=Path, action="append", help="Successful original app fixture to clone (repeat for multiple providers)")
    sources.add_argument("--prepared-root", type=Path, action="append", help="Reuse a prepared, not yet executed compaction clone")
    parser.add_argument("--prepare-only", action="store_true", help="Clone and verify fixture data without any app/provider launch")
    parser.add_argument("--artifacts", type=Path, default=Path(tempfile.gettempdir()))
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()
    try:
        app.require(args.prepare_only or args.app is not None, "Pass --app for actual acceptance or --prepare-only")
        artifacts = args.artifacts.expanduser().resolve(); artifacts.mkdir(parents=True, exist_ok=True)
        prepared = []
        if args.prepared_root:
            for path in args.prepared_root:
                root, manifest = marked_root(path)
                app.require(manifest.get("compaction_fixture") is True and app.read_json(root / "prepare-result.json").get("passed") is True,
                            "Root is not a verified compaction clone")
                app.require(not (root / "compaction-receipt.json").exists(), "Prepared clone already executed; use a fresh clone")
                prepared.append((root, manifest))
        else:
            prepared = [prepare(source, artifacts) for source in args.source_root]
        if args.prepare_only:
            print(json.dumps({"prepared_only": True, "app_launched": False, "roots": [str(root) for root, _ in prepared]}, indent=2))
            return 0
        _, executable = app.resolve_app(args.app)
        runtime = (Path.home() / "Library/Application Support/SentientOS/Private Codex").resolve()
        results = [execute(root, manifest, executable, runtime, args.timeout) for root, manifest in prepared]
        print(json.dumps({"passed": True, "providers": results}, indent=2))
        return 0
    except (app.AcceptanceFailure, OSError, ValueError, subprocess.TimeoutExpired, sqlite3.Error) as error:
        print(f"FAIL: {error}", flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
