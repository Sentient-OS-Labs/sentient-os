#!/usr/bin/env python3
"""Signed-app Sidekick acceptance, including actual old-user upgrade/relaunch.

Runs only the explicit DEBUG sidekickapp lab. Each provider gets a fresh marked support
root and isolated defaults suite. Canonical CLI authentication stays in place: no auth
copies, HOME changes, production preference writes, account mutations, or broad kills.
Artifacts are deliberately retained for independent SQLite inspection.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import sqlite3
import subprocess
import tempfile
import time
import uuid
from collections.abc import Callable

REPO = Path(__file__).resolve().parents[1]
MARKER = ".sidekick-app-fixture"
CAPABILITY = "SENTIENT_SIDEKICK_APP_LAB_DEBUG_V1"
MEMORY = "- Fixture preference: keep test replies concise.\n- Fixture memory token: LANTERN-MINT.\n"
MALFORMED = b"SIDEKICK_MIGRATION_NOT_JSON\n"
REFERENCE = "ORBIT-CEDAR"
MEMORY_REFERENCE = "LANTERN-MINT"


class AcceptanceFailure(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AcceptanceFailure(message)


def save_json(path: Path, value: object) -> None:
    encoded = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(encoded)


def read_json(path: Path) -> dict:
    require(path.is_file(), f"Missing receipt or manifest: {path.name}")
    value = json.loads(path.read_text())
    require(isinstance(value, dict), f"Expected object in {path.name}")
    return value


def fixture(root: Path, provider: str) -> dict:
    nonce = str(uuid.uuid4())
    identifier = str(uuid.uuid4()).upper()
    manifest = {"schema": 1, "nonce": nonce, "suite": "ai.sentient.sidekick-app." + nonce,
                "provider": provider, "legacy_task_id": identifier}
    namespace = uuid.UUID(nonce)
    history: list[dict] = []
    expected: list[dict] = []
    # Date's synthesized Codable representation is seconds since 2001, not Unix seconds.
    base_date = 721_692_800.0

    def entry(name: str, text: str, outcome: str, *, card: bool = False,
              modern: bool = True, status: str | None = None,
              legacy_outcome: str | None = None, blocker: str | None = None) -> None:
        row: dict = {"text": text, "card": card, "at": base_date + len(history) * 60}
        task_id = identifier if not history else str(uuid.uuid5(namespace, name)).upper()
        if modern:
            row["id"] = task_id
        if status is not None:
            row["result"] = {"outcome": outcome, "notchMessage": status}
        if legacy_outcome is not None:
            row["outcome"] = legacy_outcome
        if blocker is not None:
            row["lastRecoveryError"] = blocker
        history.append(row)
        expected.append({"name": name, "request": text, "outcome": outcome, "card": card,
                         "id": task_id if modern else None, "status": status or legacy_outcome,
                         "blocker": blocker, "at": row["at"]})

    entry("modern_success", "Fixture legacy prompt: the project codename is ORBIT-CEDAR.",
          "success", status="✓ done")
    entry("modern_stopped_card", "Fixture stopped card: draft the cobalt note.",
          "stopped", card=True, status="■ stopped")
    entry("modern_failed", "Fixture failed task: read the café 👩🏽‍💻 note.", "failed",
          status="✗ Fixture app unavailable", blocker="Fixture blocker: synthetic app was closed.")
    entry("modern_unfinished", "Fixture unfinished task: prepare a synthetic outline.", "interrupted")
    entry("old_success", "Fixture older success: prepare a synthetic summary.", "success",
          modern=False, legacy_outcome="you completed it")
    entry("old_stopped", "Fixture older stopped: inspect synthetic options.", "stopped",
          modern=False, legacy_outcome="I stopped you before it finished")
    entry("old_unknown", "Fixture older uncertain task: draft the paper kite plan.", "interrupted",
          modern=False, legacy_outcome="Prepared a draft; outcome was never classified")
    save_json(root / "fixture.json", manifest)
    save_json(root / "migration-fixture.json", {"schema": 1, "legacy_history": history,
              "memory_text": MEMORY, "expected_legacy": expected})
    (root / "suite-name.txt").write_text(manifest["suite"] + "\n")
    return manifest


def preferences(manifest: dict, *, expected: Callable[[dict], bool] | None = None,
                timeout: float = 5.0) -> dict:
    """Read the runner-owned suite through the system preferences client, not raw plist.

    cfprefsd may delay physical file writes after synchronize() and a fresh UserDefaults
    reader already sees the new value. `defaults export <exact suite> -` uses that same
    system service. Never export the original app domain or print preference contents.
    The fixed monotonic deadline never retries app stages or repairs wrong data.
    """
    suite = manifest["suite"]
    require(str(uuid.UUID(manifest["nonce"])) == manifest["nonce"]
            and suite == "ai.sentient.sidekick-app." + manifest["nonce"], "Invalid fixture suite identity")
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AcceptanceFailure("Fixture preferences did not reach the expected state within the bounded API wait")
        try:
            exported = subprocess.run(["/usr/bin/defaults", "export", suite, "-"],
                                      capture_output=True, timeout=min(2.0, remaining))
            if exported.returncode == 0:
                values = plistlib.loads(exported.stdout)
                selected = {key: values[key] for key in ["sidekick.history", "sidekick.context",
                            "sidekick.memoryMigrated", "sidekick.personalization", "lab.fixture.nonce"] if key in values}
                if expected is None or expected(selected):
                    return selected
        except (OSError, plistlib.InvalidFileException, subprocess.TimeoutExpired):
            pass
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AcceptanceFailure("Fixture preferences did not reach the expected state within the bounded API wait")
        time.sleep(min(0.1, remaining))


def legacy_matches(values: dict, expected: list[dict]) -> bool:
    data = values.get("sidekick.history")
    if not isinstance(data, bytes):
        return False
    try:
        return json.loads(data) == expected
    except (ValueError, UnicodeError):
        return False


def snapshot(root: Path) -> dict:
    path = root / "support/Sidekick/Conversation.sqlite"
    require(path.is_file(), "Actual app did not create the isolated conversation database")
    connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=5)
    try:
        connection.execute("PRAGMA query_only=ON")
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        require(integrity == "ok", "Conversation database integrity check failed")
        state = connection.execute("SELECT generation, legacy_imported, read_through FROM state WHERE singleton=1").fetchone()
        require(state is not None, "Conversation database has no state row")
        rows = connection.execute("SELECT sequence, id, task_id, kind, text, payload FROM events ORDER BY sequence").fetchall()
        records = []
        for sequence, identifier, task_id, kind, text, payload in rows:
            event = json.loads(bytes(payload))
            require(event["id"] == identifier and event["taskID"] == task_id
                    and event["kind"] == kind and event["text"] == text,
                    "Stored event columns disagree with their payload")
            records.append({"sequence": sequence, "event": event})
        tasks = connection.execute("SELECT task_id, first_sequence, started_sequence, finished_sequence FROM tasks ORDER BY first_sequence").fetchall()
        result = {"generation": state[0], "legacy_imported": state[1], "read_through": state[2],
                  "records": records, "tasks": tasks}
        canonical = json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
        result["semantic_sha256"] = hashlib.sha256(canonical).hexdigest()
        return result
    finally:
        connection.close()


def check_migration(root: Path, state: dict, manifest: dict, expected_memory: bytes | None = None) -> dict:
    migration = read_json(root / "migration-fixture.json")
    records = [row["event"] for row in state["records"]]
    require(state["legacy_imported"] == 1, "Actual startup did not commit migration marker")
    checked = 0
    for expected in migration["expected_legacy"]:
        matching = [event for event in records if event["kind"] == "userMessage" and event["text"] == expected["request"]]
        require(len(matching) == 1, f"Legacy request missing or duplicated: {expected['name']}")
        request = matching[0]
        task = [event for event in records if event["taskID"] == request["taskID"]]
        require(request.get("source") == ("proactive_card" if expected["card"] else "command"), "Legacy origin changed")
        require(request["createdAt"] == expected["at"], "Legacy timestamp changed")
        if expected["id"]:
            require(request["taskID"] == expected["id"], "Existing legacy task identity changed")
        terminal = [event for event in task if event["kind"] == "taskFinished"]
        require(len(terminal) == 1 and terminal[0].get("outcome") == expected["outcome"], "Legacy outcome changed or invented")
        if expected["status"] is not None:
            require(terminal[0]["text"] == expected["status"], "Exact legacy status was not preserved")
        require(not any(event["kind"] == "assistantMessage" for event in task), "Migration fabricated a historical assistant answer")
        if expected["blocker"]:
            require(any(event["kind"] == "checkpoint" and expected["blocker"] in event["text"] for event in task), "Legacy blocker was lost")
        checked += 1
    memory = root / "support/Sidekick/SidekickMemory.md"
    require(memory.read_bytes() == (expected_memory if expected_memory is not None else migration["memory_text"].encode()),
            "Instruction text migration or later file-authoritative edit changed unexpectedly")
    expected_text = (expected_memory.decode() if expected_memory is not None else migration["memory_text"])
    saved = preferences(manifest, expected=lambda values: "sidekick.history" not in values
                        and values.get("sidekick.memoryMigrated") is True
                        and values.get("sidekick.context") == expected_text)
    require("sidekick.history" not in saved, "Committed migration left legacy history as a second writer")
    require(saved.get("sidekick.memoryMigrated") is True, "Memory migration marker missing")
    return {"legacy_tasks_checked": checked, "memory_sha256": hashlib.sha256(memory.read_bytes()).hexdigest()}


def check_exercise(root: Path, receipt: dict, state: dict, provider: str) -> dict:
    tasks = receipt.get("tasks")
    require(isinstance(tasks, list) and tasks, "Exercise receipt has no actual submitted task IDs")
    by_role = {item.get("role"): item for item in tasks}
    require(len(by_role) == len(tasks), "Exercise task roles are duplicated")
    require({"action", "followup", "question_answer", "stopped", "after_stop", "reply"}.issubset(by_role), "Missing required end-user task path")
    receipt_ids = {str(uuid.UUID(item["task_id"])).upper() for item in tasks}
    require(len(receipt_ids) == len(tasks), "Exercise reused a task identity across submitted requests")
    events = [row["event"] for row in state["records"]]
    legacy_ids = {event["taskID"] for event in events if event["kind"] == "taskStarted" and event["id"].startswith("legacy-start:")}
    observed_ids = {row[0] for row in state["tasks"]}
    require(observed_ids - legacy_ids == receipt_ids, "Unexpected or duplicate nonlegacy task executions exist")
    answers: dict[str, str] = {}
    for role, item in by_role.items():
        task_id = str(uuid.UUID(item["task_id"])).upper()
        observed = [event for event in events if event["taskID"] == task_id]
        requests = [event for event in observed if event["kind"] == "userMessage"]
        require(len(requests) == 1 and requests[0]["text"] == item["request"], f"Actual coordinator request mismatch: {role}")
        require(requests[0].get("source") == "promptBar", f"Task did not enter through the actual prompt-bar path: {role}")
        endings = [event for event in observed if event["kind"] == "taskFinished"]
        expected_outcome = "stopped" if role == "stopped" else "success"
        require(item.get("expected_outcome") == expected_outcome, f"Unexpected receipt task expectation: {role}")
        require(len(endings) == 1 and endings[0].get("outcome") == expected_outcome, f"Actual task outcome mismatch: {role}")
        answer_events = [event for event in observed if event["kind"] == "assistantMessage" and event.get("messageKind") == "answer"]
        if role != "stopped":
            require(any(not event["id"].startswith("fallback:") for event in answer_events),
                    f"Successful task did not explicitly deliver a message_user answer: {role}")
        if role == "action":
            require(any(event.get("priority") == "high" and not event["id"].startswith("fallback:") for event in answer_events),
                    "Initial action did not explicitly request priority attention")
        answers[role] = "\n".join(event["text"] for event in answer_events)
        if role == "stopped":
            pending = [event for event in observed if event["kind"] == "question"]
            choices = pending[-1].get("choices", []) if pending else []
            require(len(choices) == 2 and set(choices) == {"Left", "Right"}, "Stop did not exercise the exact pending Left/Right question")
            require(not any(event["kind"] == "answer" for event in observed), "Stopped question received an invented user answer")
            require("Stopped by user" in endings[0]["text"], "Stopped task did not record an actual user Stop")
        if role == "question_answer":
            supplied = item.get("expected_answer")
            require(isinstance(supplied, str) and supplied, "Answered-question receipt lacks actual fixture choice")
            require(any(event["kind"] == "answer" and event["text"] == supplied for event in observed), "Real recovery answer was not recorded")
        if role == "reply":
            reference = requests[0].get("reply", {})
            require(isinstance(item.get("source_message_id"), str) and isinstance(item.get("expected_quote"), str)
                    and bool(item["expected_quote"]), "Reply receipt lacks a real source and selected quote")
            source = next((event for event in events if event["id"] == item["source_message_id"]), None)
            require(source is not None and item["expected_quote"] in source["text"], "Reply quote is not from stored history")
            require(reference.get("messageID") == item.get("source_message_id"), "Reply points at wrong source")
            require(reference.get("selectedText") == item.get("expected_quote"), "Selected reply quote changed")
    action = receipt.get("observed_action", {})
    expected = "SIDEKICK-" + provider + "-VERIFIED"
    require(action.get("kind") == "native_text_field_and_button", "Native action observation is missing")
    require(action.get("expected_text") == expected and action.get("observed_text") == expected, "Fixture text field did not contain requested value")
    require(action.get("action_count") == 1, "Native Reveal button was not activated exactly once")
    revealed = action.get("revealed_token")
    require(isinstance(revealed, str) and len(revealed) >= 8, "No actual hidden fixture token was revealed")
    initial_request = by_role["action"]["request"]
    for token in [REFERENCE, MEMORY_REFERENCE, revealed]:
        require(token not in initial_request, "Acceptance answer was leaked into the initial request")
        require(token in answers["action"], "Action answer omitted real migrated/native context")
    require(expected in answers["action"], "Action answer omitted the verified field value")
    require(expected in answers["followup"] and revealed in answers["followup"], "Followup lost previous task's actual result")
    action_task = str(uuid.UUID(by_role["action"]["task_id"])).upper()
    activity = [event.get("activity", {}) for event in events if event["taskID"] == action_task and event["kind"] == "activity"]
    def leaf(name: str) -> str:
        return name.replace("__", ".").rsplit(".", 1)[-1].lower()
    native_actions = {leaf(item.get("name", "")) for item in activity
                      if "sentient_native" in item.get("name", "") and item.get("status") == "completed"}
    require("click" in native_actions and bool({"set_value", "type_text", "press_key"} & native_actions),
            "Native action lacks completed click and text-entry execution evidence")
    selector = receipt.get("native_app_selector")
    require(isinstance(selector, str) and selector.startswith("/") and selector.endswith(".app")
            and selector in initial_request, "Missing exact fixture app selector")
    targeted = [item for item in activity if "sentient_native" in item.get("name", "")
                and leaf(item.get("name", "")) != "list_apps"]
    require(targeted and all(json.loads(item.get("arguments") or "{}").get("app") == selector
                             for item in targeted), "Native calls used an ambiguous or different app selector")
    shell_names = {"command_execution", "local_shell_call", "bash", "exec_command", "shell_command", "write_stdin"}
    require(not any(leaf(item.get("name", "")) in shell_names
                    or "node_repl" in item.get("name", "") for item in activity),
            "Native-only action used a shell/JavaScript substitute")
    followup_id = str(uuid.UUID(by_role["followup"]["task_id"])).upper()
    followup_activity = [event.get("activity", {}) for event in events
                        if event["taskID"] == followup_id and event["kind"] == "activity"]
    require(not any("sentient_native" in item.get("name", "")
                    or leaf(item.get("name", "")) in shell_names
                    or "node_repl" in item.get("name", "") for item in followup_activity),
            "History-only followup reread the app or used a shell/JavaScript substitute")
    require("left" in answers["after_stop"].lower() and "right" in answers["after_stop"].lower(), "Post-Stop answer lost pending choices")
    require("ANSWER_STATE: UNANSWERED" in answers["after_stop"] and "ANSWER_STATE: ANSWERED" not in answers["after_stop"],
            "Post-Stop answer did not preserve the unanswered state")
    all_activity = [event["activity"] for event in events if event["kind"] == "activity"]
    require(not any("sentient_recovery" in item["name"] and leaf(item["name"]) == "describe_task_usage"
                    for item in all_activity), "Telemetry appeared in conversation activity")
    native_results = [item for item in all_activity
                      if "sentient_native" in item["name"] and item["status"] in {"completed", "failed"}]
    require(all(item.get("result") in {"Tool returned a result. Output omitted.", "Tool reported a failure. Output omitted."}
                for item in native_results), "Raw native capture or accessibility output entered conversation storage")
    return {"actual_tasks_checked": len(tasks), "native_action_count": action["action_count"],
            "native_token_in_durable_answer": True, "followup_continuity": True, "stopped_continuity": True,
            "telemetry_excluded": True, "native_result_payloads_omitted": True}


def resolve_app(path: Path) -> tuple[Path, Path]:
    path = path.expanduser().resolve()
    bundle = path if path.suffix == ".app" else next((parent for parent in path.parents if parent.suffix == ".app"), None)
    require(bundle is not None and bundle.is_dir(), "--app must identify a signed app bundle or its executable")
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    executable = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
    require(executable.is_file() and os.access(executable, os.X_OK), "App executable is unavailable")
    capability = CAPABILITY.encode() in executable.read_bytes()
    if not capability:
        # Xcode's Debug launcher may put Swift code in a linked .debug.dylib. An arbitrary
        # leftover sidecar is not evidence: it must be an actual launcher dependency.
        dependencies = subprocess.run(["/usr/bin/xcrun", "otool", "-L", str(executable)], capture_output=True, text=True)
        require(dependencies.returncode == 0, "Could not validate the Debug launcher's loaded code")
        linked = {line.strip().split(" (compatibility version", 1)[0].rsplit("/", 1)[-1]
                  for line in dependencies.stdout.splitlines()[1:]}
        capability = any(library.name in linked and CAPABILITY.encode() in library.read_bytes()
                         for library in executable.parent.glob("*.debug.dylib"))
    require(capability, "Refusing to launch: loaded code lacks the explicit DEBUG Sidekick app-lab capability")
    verified = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)], capture_output=True, text=True)
    require(verified.returncode == 0, "App signature verification failed")
    details = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=2", str(bundle)], capture_output=True, text=True)
    require(details.returncode == 0 and "Signature=adhoc" not in details.stderr
            and "TeamIdentifier=not set" not in details.stderr and "TeamIdentifier=" in details.stderr,
            "Acceptance requires a development-signed app, not an ad-hoc build")
    return bundle, executable


def stop_owned(process: subprocess.Popen, root: Path) -> None:
    """Signal only the new session owned by this runner; never pkill a shared native helper."""
    (root / "stop-request").write_text("timeout\n")
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


def run_stage(executable: Path, root: Path, manifest: dict, runtime: Path, stage: str, timeout: int) -> dict:
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("SENTIENT_", "LAB_"))}
    environment.update({"SENTIENT_SELFTEST": "sidekickapp", "LAB_SIDEKICK_ROOT": str(root),
                        "LAB_SIDEKICK_STAGE": stage, "LAB_SIDEKICK_PROVIDER": manifest["provider"],
                        "SENTIENT_CODEX_RUNTIME_ROOT": str(runtime), "SENTIENT_VAULT_ROOT": str(root / "vault")})
    receipt_path = root / (stage + "-receipt.json")
    require(not receipt_path.exists(), "Refusing to reuse a stale stage receipt")
    with (root / (stage + ".stdout.log")).open("wb") as stdout, (root / (stage + ".stderr.log")).open("wb") as stderr:
        process = subprocess.Popen([str(executable)], env=environment, cwd=root,
                                   stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            stop_owned(process, root)
            raise AcceptanceFailure(f"Stage {stage} interrupted/timed out; only its owned process group was stopped") from None
    require(code == 0, f"Actual signed app exited {code} during {stage}; see retained stage logs")
    receipt = read_json(receipt_path)
    require(receipt.get("lab_capability") == CAPABILITY, "App did not execute the isolated DEBUG lab entry")
    require(receipt.get("stage") == stage and receipt.get("provider") == manifest["provider"]
            and receipt.get("suite") == manifest["suite"], "Receipt identity does not match the launched fixture")
    checks = receipt.get("checks")
    require(receipt.get("passed") is True and isinstance(checks, dict) and checks
            and all(value is True for value in checks.values()), f"App-reported checks failed during {stage}")
    return receipt


def run_provider(executable: Path, artifacts: Path, provider: str, runtime: Path, timeout: int,
                 migration_failure: bool) -> dict:
    root = Path(tempfile.mkdtemp(prefix=f"sentient-sidekick-app-{provider}-", dir=artifacts)).resolve()
    root.chmod(0o700)
    require(not runtime.is_relative_to(root), "Canonical authentication cannot be inside fixture support")
    (root / MARKER).write_bytes(b"1\n")
    (root / "vault").mkdir(mode=0o700)
    manifest = fixture(root, provider)
    print(f"[{provider}] fixture: {root}", flush=True)
    result: dict = {"provider": provider, "root": str(root), "suite": manifest["suite"], "passed": False}
    try:
        run_stage(executable, root, manifest, runtime, "seed", 60)
        migration = read_json(root / "migration-fixture.json")
        old = preferences(manifest, expected=lambda values: legacy_matches(values, migration["legacy_history"])
                          and values.get("sidekick.context") == MEMORY)
        require(isinstance(old.get("sidekick.history"), bytes) and json.loads(old["sidekick.history"]) == migration["legacy_history"], "Seed did not persist exact old-format history")
        require(old.get("sidekick.context") == MEMORY, "Seed did not persist exact old instruction text")
        require(not (root / "support/Sidekick/Conversation.sqlite").exists(), "Seed prematurely created new conversation store")
        require(not (root / "support/Sidekick/SidekickMemory.md").exists(), "Seed prematurely migrated memory")
        if migration_failure:
            run_stage(executable, root, manifest, runtime, "migration_failure", 90)
            require(preferences(manifest, expected=lambda values: values.get("sidekick.history") == MALFORMED).get("sidekick.history") == MALFORMED, "Failed migration did not preserve malformed fixture source bytes")
            failed = snapshot(root)
            require(failed["legacy_imported"] == 0 and not failed["records"], "Failed migration partially imported or started a task")
            run_stage(executable, root, manifest, runtime, "repair", 60)
            require(json.loads(preferences(manifest, expected=lambda values: legacy_matches(values, migration["legacy_history"]))["sidekick.history"]) == migration["legacy_history"], "Repair did not restore only the original fixture source")
            repaired = snapshot(root)
            require(failed["semantic_sha256"] == repaired["semantic_sha256"], "Repair deleted/reset/replaced the initialized database")
            result["failed_migration_preserved_and_repaired"] = True
        receipt = run_stage(executable, root, manifest, runtime, "exercise", timeout)
        exercised = snapshot(root)
        result.update(check_migration(root, exercised, manifest))
        result.update(check_exercise(root, receipt, exercised, provider))
        save_json(root / "independent-exercise-snapshot.json", exercised)
        memory_path = root / "support/Sidekick/SidekickMemory.md"
        memory_after_user_edit = memory_path.read_bytes() + b"- Fixture user edit after update: USER-EDIT-KEEP-519.\n"
        memory_path.write_bytes(memory_after_user_edit)
        (root / "reopen-memory-expected.txt").write_bytes(memory_after_user_edit)
        run_stage(executable, root, manifest, runtime, "reopen", 90)
        reopened = snapshot(root)
        check_migration(root, reopened, manifest, expected_memory=memory_after_user_edit)
        require(reopened["semantic_sha256"] == exercised["semantic_sha256"], "Relaunch changed task identities/events or repeated migration")
        require(memory_path.read_bytes() == memory_after_user_edit, "Relaunch overwrote file-backed user edit")
        require(preferences(manifest, expected=lambda values: values.get("sidekick.context") == memory_after_user_edit.decode()).get("sidekick.context") == memory_after_user_edit.decode(),
                "Reopened app did not adopt the external memory file edit")
        save_json(root / "independent-reopen-snapshot.json", reopened)
        result.update({"passed": True, "relaunch_idempotent": True, "event_count": len(reopened["records"]),
                       "task_count": len(reopened["tasks"]), "semantic_sha256": reopened["semantic_sha256"]})
    except Exception as error:
        result["failure"] = str(error)
        save_json(root / "runner-result.json", result)
        raise AcceptanceFailure(f"{provider}: {error}; artifacts retained at {root}") from None
    save_json(root / "runner-result.json", result)
    print(f"[{provider}] PASS: {result['actual_tasks_checked']} actual tasks; {result['legacy_tasks_checked']} migrated legacy tasks; real native fixture + relaunch verified", flush=True)
    return result


def build_app(artifacts: Path, scheme: str) -> Path:
    build_root = Path(tempfile.mkdtemp(prefix="sentient-sidekick-build-", dir=artifacts)).resolve()
    derived = build_root / "DerivedData"
    with (build_root / "build.log").open("wb") as output:
        result = subprocess.run(["/usr/bin/xcodebuild", "-project", str(REPO / "Sentient OS macOS.xcodeproj"),
                                 "-scheme", scheme, "-configuration", "Debug", "-derivedDataPath", str(derived),
                                 "CODE_SIGNING_ALLOWED=YES", "build"], cwd=REPO, stdout=output, stderr=subprocess.STDOUT, timeout=1800)
    require(result.returncode == 0, f"Signed Debug build failed; see {build_root / 'build.log'}")
    bundles = list((derived / "Build/Products/Debug").glob("*.app"))
    require(len(bundles) == 1, "Build produced ambiguous app bundles; pass --app explicitly")
    return bundles[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--app", type=Path, help="Existing development-signed Debug .app or executable")
    target.add_argument("--build", action="store_true", help="Build a signed Debug app using isolated DerivedData")
    parser.add_argument("--scheme", default="Sentient OS macOS")
    parser.add_argument("--provider", choices=["chatgpt", "claude"], action="append", help="Default: both, sequentially")
    parser.add_argument("--artifacts", type=Path, default=Path(tempfile.gettempdir()), help="Parent directory for retained owned fixtures")
    parser.add_argument("--runtime-root", type=Path, default=Path.home() / "Library/Application Support/SentientOS/Private Codex")
    parser.add_argument("--exercise-timeout", type=int, default=900)
    parser.add_argument("--skip-migration-failure", action="store_true", help="Skip the additional malformed-source repair probe")
    args = parser.parse_args()
    try:
        artifacts = args.artifacts.expanduser().resolve()
        artifacts.mkdir(parents=True, exist_ok=True)
        runtime = args.runtime_root.expanduser().resolve()
        release = read_json(REPO / "Sentient OS macOS/Cloud/BundledCodexRelease.json")
        require((runtime / "releases" / ("cli-" + release["cli"]["version"]) / "bin/codex").is_file(), "Canonical pinned runtime is not installed")
        require(args.exercise_timeout >= 60, "Exercise timeout must allow the real provider to complete")
        bundle, executable = resolve_app(args.app if args.app else build_app(artifacts, args.scheme))
        providers = list(dict.fromkeys(args.provider or ["chatgpt", "claude"]))
        results = []
        for index, provider in enumerate(providers):
            results.append(run_provider(executable, artifacts, provider, runtime, args.exercise_timeout,
                                        migration_failure=index == 0 and not args.skip_migration_failure))
        print(json.dumps({"passed": True, "app": str(bundle), "providers": results}, ensure_ascii=False, indent=2))
        return 0
    except (AcceptanceFailure, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
