#!/usr/bin/env python3
"""Run Phase 02 qualification without converting missing prerequisites into success."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import platform
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


MAX_OUTPUT_BYTES = 1_048_576
READINESS_VALUES = {
    "ready",
    "degraded",
    "blocked",
    "unsupported",
    "externally-constrained",
}
AUTHORITATIVE_ROW_TABLES = {
    "projects",
    "desired_services",
    "operation_ledger",
    "ownership_records",
    "restart_policy_state",
    "restart_recovery_records",
    "operation_groups",
    "operation_group_steps",
}


class QualificationFailure(RuntimeError):
    pass


class QualificationBlocked(RuntimeError):
    pass


@dataclass(frozen=True)
class CommandResult:
    label: str
    argv: tuple[str, ...]
    exit_code: int
    duration_ms: int
    stdout: str
    stderr: str


class Recorder:
    def __init__(self) -> None:
        self.commands: list[dict[str, Any]] = []
        self.details: list[dict[str, Any]] = []

    def add(self, result: CommandResult, *, assertion_passed: bool = True) -> None:
        self.commands.append(
            {
                "command": result.label,
                "exitCode": 0 if assertion_passed else result.exit_code or 1,
                "durationMilliseconds": result.duration_ms,
            }
        )
        self.details.append(
            {
                "command": result.label,
                "observedExitCode": result.exit_code,
                "stdoutSHA256": sha256_bytes(result.stdout.encode()),
                "stderrSHA256": sha256_bytes(result.stderr.encode()),
            }
        )

    def assertion(self, label: str, passed: bool, detail: str = "") -> None:
        self.commands.append(
            {"command": label, "exitCode": 0 if passed else 1, "durationMilliseconds": 0}
        )
        self.details.append(
            {
                "command": label,
                "observedExitCode": 0 if passed else 1,
                "detail": detail,
            }
        )
        if not passed:
            raise QualificationFailure(f"{label}: {detail or 'assertion failed'}")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def safe_file(path: str, *, executable: bool = False) -> Path:
    candidate = Path(path)
    if not candidate.is_absolute():
        raise QualificationBlocked(f"required path is not absolute: {path}")
    try:
        metadata = candidate.lstat()
    except FileNotFoundError as error:
        raise QualificationBlocked(f"required file is unavailable: {path}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise QualificationBlocked(f"required path is not a regular non-symlink file: {path}")
    if executable and not os.access(candidate, os.X_OK):
        raise QualificationBlocked(f"required executable is not executable: {path}")
    return candidate


def safe_new_directory(path: str) -> Path:
    candidate = Path(path)
    if not candidate.is_absolute() or candidate.exists() or candidate.is_symlink():
        raise QualificationBlocked("output directory must be an absent absolute path")
    candidate.mkdir(mode=0o700, parents=False)
    return candidate


def resolved_executable(explicit: str | None, name: str) -> Path:
    value = explicit or shutil.which(name)
    if not value:
        raise QualificationBlocked(f"required executable is unavailable: {name}")
    return safe_file(str(Path(value).resolve()), executable=True)


def run(
    argv: Iterable[str],
    label: str,
    *,
    timeout: int = 300,
    expected: set[int] | None = None,
    recorder: Recorder | None = None,
    cwd: Path | None = None,
) -> CommandResult:
    values = tuple(str(item) for item in argv)
    started = time.monotonic()
    try:
        completed = subprocess.run(
            values,
            cwd=str(cwd) if cwd else None,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
            start_new_session=True,
        )
    except subprocess.TimeoutExpired as error:
        raise QualificationFailure(f"{label} exceeded {timeout} seconds") from error
    duration = int((time.monotonic() - started) * 1000)
    if len(completed.stdout) > MAX_OUTPUT_BYTES or len(completed.stderr) > MAX_OUTPUT_BYTES:
        raise QualificationFailure(f"{label} exceeded the 1 MiB captured-output limit")
    result = CommandResult(
        label=label,
        argv=values,
        exit_code=completed.returncode,
        duration_ms=duration,
        stdout=completed.stdout.decode("utf-8", errors="replace"),
        stderr=completed.stderr.decode("utf-8", errors="replace"),
    )
    accepted = expected if expected is not None else {0}
    passed = result.exit_code in accepted
    if recorder is not None:
        recorder.add(result, assertion_passed=passed)
    if not passed:
        raise QualificationFailure(
            f"{label} exited {result.exit_code}; expected {sorted(accepted)}"
        )
    return result


def run_rejection(
    argv: Iterable[str],
    label: str,
    recorder: Recorder,
    *,
    expected_codes: set[int] | None = None,
    required_text: str | None = None,
    timeout: int = 300,
) -> CommandResult:
    result = run(argv, label, timeout=timeout, expected=set(range(-255, 256)), recorder=None)
    accepted = expected_codes or {code for code in range(-255, 256) if code != 0}
    passed = result.exit_code in accepted
    if required_text is not None:
        passed = passed and required_text in (result.stdout + result.stderr)
    recorder.add(result, assertion_passed=passed)
    if not passed:
        raise QualificationFailure(f"{label} did not fail closed as expected")
    return result


def json_output(result: CommandResult, label: str) -> dict[str, Any]:
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise QualificationFailure(f"{label} did not return one JSON document") from error
    if not isinstance(value, dict):
        raise QualificationFailure(f"{label} JSON is not an object")
    return value


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def inventory(container: Path, recorder: Recorder, label: str) -> tuple[str, dict[str, Any]]:
    result = run(
        [container, "list", "--all", "--format", "json"],
        label,
        timeout=60,
        recorder=recorder,
    )
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise QualificationFailure("Apple container inventory was not valid JSON") from error
    return sha256_bytes(canonical_json(value)), {"inventory": value}


def source_truth(root: Path) -> tuple[str, bool]:
    head = run(["/usr/bin/git", "-C", root, "rev-parse", "HEAD"], "read source commit").stdout.strip()
    dirty_output = run(
        ["/usr/bin/git", "-C", root, "status", "--porcelain=v1", "--untracked-files=all"],
        "read source dirty state",
    ).stdout
    if len(head) != 40 or any(character not in "0123456789abcdef" for character in head):
        raise QualificationBlocked("source checkout does not resolve to a full Git commit")
    return head, bool(dirty_output.strip())


def host_environment(tool_versions: dict[str, str]) -> dict[str, Any]:
    def output(argv: list[str], fallback: str) -> str:
        try:
            value = run(argv, "read host environment", timeout=30).stdout.strip()
            return value or fallback
        except (QualificationFailure, QualificationBlocked):
            return fallback

    return {
        "operatingSystem": output(["/usr/bin/sw_vers", "-productVersion"], platform.mac_ver()[0] or "unknown"),
        "build": output(["/usr/bin/sw_vers", "-buildVersion"], "unknown"),
        "architecture": platform.machine() or "unknown",
        "hardwareModel": output(["/usr/sbin/sysctl", "-n", "hw.model"], "unknown"),
        "memoryBytes": int(output(["/usr/sbin/sysctl", "-n", "hw.memsize"], "1")),
        "toolVersions": tool_versions,
    }


def evidence_report(
    *,
    evidence_class: str,
    source_commit: str,
    dirty: bool,
    recorder: Recorder,
    tool_versions: dict[str, str],
    cleanup_status: str,
    cleanup_ids: list[str],
    status: str = "passed",
    failures: list[str] | None = None,
    blockers: list[str] | None = None,
) -> dict[str, Any]:
    failures = failures or []
    blockers = blockers or []
    if not recorder.commands:
        recorder.assertion(
            "qualification command presence",
            True,
            "no qualification command executed",
        )
        if status == "passed":
            blockers.append("no qualification command executed")
    if cleanup_status not in {"not-required", "succeeded", "failed"}:
        raise QualificationFailure(f"unsupported cleanup status: {cleanup_status}")
    command_failures = sum(1 for command in recorder.commands if command["exitCode"] != 0)
    if status == "failed" and not failures:
        failures.append("qualification failed")
    if status == "blocked" and not blockers:
        blockers.append("a qualification prerequisite is blocked")
    if command_failures and not failures:
        failures.append("one or more qualification commands failed")
    if cleanup_status == "failed":
        failures.append("exact qualification cleanup failed")
    if failures:
        status = "failed"
    elif dirty:
        status = "blocked"
        blockers.append("the source checkout is dirty; release evidence requires an exact clean commit")
    elif blockers:
        status = "blocked"
    passed = sum(1 for command in recorder.commands if command["exitCode"] == 0)
    failed = command_failures + (1 if status == "failed" and command_failures == 0 else 0)
    blocked = 1 if status == "blocked" else 0
    return {
        "schemaVersion": 1,
        "evidenceClass": evidence_class,
        "status": status,
        "recordedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "source": {"commit": source_commit, "dirty": dirty},
        "environment": host_environment(tool_versions),
        "commands": recorder.commands,
        "rawResults": {
            "executed": passed + failed + blocked,
            "passed": passed,
            "failed": failed,
            "blocked": blocked,
        },
        "failures": failures,
        "blockers": blockers,
        "cleanup": {
            "status": cleanup_status,
            "exactResourceIdentifiers": cleanup_ids,
        },
    }


def write_json(path: Path, value: Any, mode: int = 0o600) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(path, flags, mode)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        raise


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def replace_json(path: Path, value: Any, mode: int = 0o600) -> None:
    metadata = path.lstat()
    if (not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode)
            or metadata.st_uid != os.geteuid() or metadata.st_nlink != 1):
        raise QualificationFailure("power-loss acknowledgment record identity changed")
    replacement = path.with_name(f".{path.name}.{uuid.uuid4().hex}.next")
    try:
        write_json(replacement, value, mode=mode)
        os.replace(replacement, path)
        fsync_directory(path.parent)
    finally:
        if replacement.exists():
            replacement.unlink()


def canonical_row_hashes(database: Path) -> dict[str, dict[str, Any]]:
    immutable = not Path(str(database) + "-wal").exists()
    suffix = "&immutable=1" if immutable else ""
    connection = sqlite3.connect(f"file:{database}?mode=ro{suffix}", uri=True)
    try:
        tables = [
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
            )
        ]
        result: dict[str, dict[str, Any]] = {}
        for table in tables:
            quoted = '"' + table.replace('"', '""') + '"'
            rows = connection.execute(f"SELECT * FROM {quoted} ORDER BY rowid").fetchall()
            encoded = canonical_json(rows)
            result[table] = {"rows": len(rows), "sha256": sha256_bytes(encoded)}
        return result
    finally:
        connection.close()


def authoritative_row_hashes(database: Path) -> dict[str, dict[str, Any]]:
    hashes = canonical_row_hashes(database)
    return {
        table: hashes[table]
        for table in sorted(AUTHORITATIVE_ROW_TABLES & hashes.keys())
    }


def backup_root_for(database: Path) -> Path:
    digest = hashlib.sha256(str(database).encode()).digest()[:8].hex()
    return database.parent / f".hostwright-{digest}-backups"


def require_kind(value: dict[str, Any], kind: str, label: str) -> None:
    if value.get("kind") != kind:
        raise QualificationFailure(f"{label} returned unexpected kind {value.get('kind')!r}")


def focused_tests(root: Path, recorder: Recorder) -> None:
    run(
        ["/usr/bin/swift", "test", "--filter", "StateMaintenance"],
        "run state-maintenance focused tests",
        timeout=1200,
        recorder=recorder,
        cwd=root,
    )
    run(
        ["/usr/bin/swift", "test", "--filter", "SQLiteHardeningTests"],
        "run SQLite hardening focused tests",
        timeout=1200,
        recorder=recorder,
        cwd=root,
    )
    run(
        ["/usr/bin/swift", "test", "--filter", "DoctorSystemProbeTests"],
        "run doctor-system focused tests",
        timeout=1200,
        recorder=recorder,
        cwd=root,
    )


def state_command(args: argparse.Namespace) -> int:
    root = Path(args.source_root).resolve()
    hostwright = safe_file(args.hostwright, executable=True)
    prior = safe_file(args.prior_hostwright, executable=True)
    manifest = safe_file(args.manifest)
    container = resolved_executable(args.container, "container")
    output = safe_new_directory(args.output_dir)
    recorder = Recorder()
    commit, dirty = source_truth(root)
    work = Path(tempfile.mkdtemp(prefix="hostwright-phase02-state-"))
    os.chmod(work, 0o700)
    cleanup_id = work.name
    state = work / "current" / "state.sqlite"
    prior_state = work / "prior" / "state.sqlite"
    state.parent.mkdir(mode=0o700)
    prior_state.parent.mkdir(mode=0o700)
    details: dict[str, Any] = {"cleanupIdentifier": cleanup_id}
    cleanup_status = "failed"
    try:
        current_version = run([hostwright, "--version"], "read candidate Hostwright version", recorder=recorder).stdout.strip()
        prior_version = run([prior, "--version"], "read prior Hostwright version", recorder=recorder).stdout.strip()
        recorder.assertion(
            "prior contract executable differs from candidate",
            sha256_file(prior) != sha256_file(hostwright),
            "prior and candidate executable digests must differ",
        )
        allowed_transitions = {
            ("0.0.2-dev", "0.0.2-dev.1"),
            ("0.0.2-dev", "0.0.2-dev.2"),
            ("0.0.2-dev.1", "0.0.2-dev.2"),
            ("0.0.2-dev.3", "0.0.2-dev.4"),
            ("0.0.2-dev.5", "0.0.2-dev.6"),
            ("0.0.2-dev.8", "0.0.2-dev.9"),
            ("0.0.2-dev.11", "0.0.2-dev.12"),
        }
        recorder.assertion(
            "earlier contract and candidate versions match a Phase 02 transition",
            (prior_version, current_version) in allowed_transitions,
            f"unsupported transition {prior_version!r} -> {current_version!r}",
        )
        container_version = run([container, "--version"], "read Apple container version", recorder=recorder).stdout.strip()

        before_hash, _ = inventory(container, recorder, "observe Apple inventory before state workflow")
        status = run(
            [hostwright, "status", manifest, "--state-db", state, "--output", "json"],
            "create state through real read-only Apple observation",
            timeout=120,
            recorder=recorder,
        )
        json_output(status, "Hostwright status")
        after_hash, _ = inventory(container, recorder, "observe Apple inventory after state workflow")
        recorder.assertion("Apple inventory is unchanged by read-only observation", before_hash == after_hash)

        integrity = json_output(
            run(
                [hostwright, "state", "integrity", "--state-db", state, "--json"],
                "verify initial state integrity",
                recorder=recorder,
            ),
            "state integrity",
        )
        require_kind(integrity, "stateIntegrityReport", "state integrity")
        recorder.assertion("initial state is healthy", integrity.get("health") == "healthy")

        backup = json_output(
            run(
                [hostwright, "state", "backup", "--state-db", state, "--json"],
                "create verified online backup",
                recorder=recorder,
            ),
            "state backup",
        )
        require_kind(backup, "stateBackupRecord", "state backup")
        backup_id = str(backup.get("backupID", ""))
        backup_db = backup_root_for(state) / backup_id / "state.sqlite"
        recorder.assertion("published backup database exists", backup_db.is_file())
        recorder.assertion(
            "published backup digest matches its record",
            sha256_file(backup_db) == backup.get("databaseSHA256"),
        )
        baseline_rows = canonical_row_hashes(backup_db)

        stale_plan = json_output(
            run(
                [hostwright, "state", "restore", "--backup", backup_id, "--dry-run", "--state-db", state, "--json"],
                "create restore dry-run for stale-token test",
                recorder=recorder,
            ),
            "restore dry-run",
        )
        run(
            [hostwright, "status", manifest, "--state-db", state, "--output", "json"],
            "change state after restore dry-run",
            recorder=recorder,
        )
        run_rejection(
            [
                hostwright,
                "state",
                "restore",
                "--backup",
                backup_id,
                "--confirm-restore",
                str(stale_plan.get("confirmationToken", "")),
                "--state-db",
                state,
                "--json",
            ],
            "reject stale restore confirmation",
            recorder,
            expected_codes={70},
            required_text="HW-CLI-003",
        )

        def restore(label: str) -> dict[str, Any]:
            plan = json_output(
                run(
                    [hostwright, "state", "restore", "--backup", backup_id, "--dry-run", "--state-db", state, "--json"],
                    f"plan {label}",
                    recorder=recorder,
                ),
                f"{label} plan",
            )
            return json_output(
                run(
                    [
                        hostwright,
                        "state",
                        "restore",
                        "--backup",
                        backup_id,
                        "--confirm-restore",
                        str(plan.get("confirmationToken", "")),
                        "--state-db",
                        state,
                        "--json",
                    ],
                    label,
                    recorder=recorder,
                ),
                label,
            )

        normal_restore = restore("restore verified backup")
        require_kind(normal_restore, "stateRestoreResult", "state restore")
        post_restore_backup = json_output(
            run(
                [hostwright, "state", "backup", "--state-db", state, "--json"],
                "back up restored state for row-hash comparison",
                recorder=recorder,
            ),
            "post-restore backup",
        )
        restored_db = backup_root_for(state) / str(post_restore_backup["backupID"]) / "state.sqlite"
        restored_rows = canonical_row_hashes(restored_db)
        compared_tables = sorted(AUTHORITATIVE_ROW_TABLES & baseline_rows.keys() & restored_rows.keys())
        recorder.assertion(
            "authoritative row hashes survive backup and restore",
            bool(compared_tables)
            and all(baseline_rows[name] == restored_rows[name] for name in compared_tables),
        )

        original = state.read_bytes()
        state.write_bytes(b"not a sqlite database")
        os.chmod(state, 0o600)
        corrupt = run_rejection(
            [hostwright, "state", "integrity", "--state-db", state, "--json"],
            "classify corrupt state",
            recorder,
            expected_codes={66},
            required_text="HW-STATE-001",
        )
        recorder.assertion(
            "corrupt state is reported unrecoverable",
            json.loads(corrupt.stdout).get("health") == "unrecoverable",
        )
        corrupt_restore = restore("restore corrupt state and quarantine original")
        quarantine = corrupt_restore.get("quarantinedDatabasePath")
        recorder.assertion("corrupt original is quarantined", isinstance(quarantine, str) and Path(quarantine).is_file())

        state.write_bytes(original[:32])
        os.chmod(state, 0o600)
        truncated = run_rejection(
            [hostwright, "state", "integrity", "--state-db", state, "--json"],
            "classify truncated state",
            recorder,
            expected_codes={66},
            required_text="HW-STATE-001",
        )
        recorder.assertion(
            "truncated state is reported unrecoverable",
            json.loads(truncated.stdout).get("health") == "unrecoverable",
        )
        restore("restore truncated state and quarantine original")
        recovery = json_output(
            run(
                [hostwright, "state", "recover", "--state-db", state, "--json"],
                "verify idempotent maintenance recovery",
                recorder=recorder,
            ),
            "state recovery",
        )
        require_kind(recovery, "stateRecoveryResult", "state recovery")

        prior_status = run(
            [prior, "status", manifest, "--state-db", prior_state, "--output", "json"],
            "create database with actual earlier contract executable",
            timeout=120,
            recorder=recorder,
        )
        json_output(prior_status, "prior Hostwright status")
        prior_rows = canonical_row_hashes(prior_state)
        run(
            [hostwright, "status", manifest, "--state-db", prior_state, "--output", "json"],
            "migrate earlier-contract database with candidate",
            timeout=120,
            recorder=recorder,
        )
        migrated_integrity = json_output(
            run(
                [hostwright, "state", "integrity", "--state-db", prior_state, "--json"],
                "verify migrated earlier-contract database",
                recorder=recorder,
            ),
            "migrated state integrity",
        )
        recorder.assertion(
            "earlier-contract database migrated to schema v7",
            migrated_integrity.get("health") == "healthy"
            and migrated_integrity.get("stateSchemaVersion") == 7,
        )
        migrated_backup = json_output(
            run(
                [hostwright, "state", "backup", "--state-db", prior_state, "--json"],
                "back up migrated earlier-contract database",
                recorder=recorder,
            ),
            "migrated backup",
        )
        migrated_db = backup_root_for(prior_state) / str(migrated_backup["backupID"]) / "state.sqlite"
        migrated_rows = canonical_row_hashes(migrated_db)
        prior_common = sorted(AUTHORITATIVE_ROW_TABLES & prior_rows.keys() & migrated_rows.keys())
        recorder.assertion(
            "earlier-contract authoritative rows survive migration",
            bool(prior_common)
            and all(prior_rows[name] == migrated_rows[name] for name in prior_common),
        )

        focused_tests(root, recorder)
        details.update(
            {
                "sourceCommit": commit,
                "candidateVersion": current_version,
                "priorVersion": prior_version,
                "priorExecutableSHA256": sha256_file(prior),
                "candidateExecutableSHA256": sha256_file(hostwright),
                "containerVersion": container_version,
                "inventoryBeforeSHA256": before_hash,
                "inventoryAfterSHA256": after_hash,
                "backupDatabaseSHA256": sha256_file(backup_db),
                "baselineRowHashes": baseline_rows,
                "restoredRowHashes": restored_rows,
                "migratedRowHashes": migrated_rows,
                "comparedAuthoritativeTables": compared_tables,
            }
        )
        cleanup_status = "succeeded"
    finally:
        shutil.rmtree(work, ignore_errors=False)
        if work.exists():
            cleanup_status = "failed"

    tool_versions = {
        "hostwright": details.get("candidateVersion", "unknown"),
        "prior-hostwright": details.get("priorVersion", "unknown"),
        "container": details.get("containerVersion", "unknown"),
        "python": platform.python_version(),
    }
    write_json(output / "state-qualification-details.json", {"commands": recorder.details, **details})
    for evidence_class in [
        "local-integration",
        "live-runtime",
        "migration-upgrade",
        "security-assessment",
    ]:
        write_json(
            output / f"state-{evidence_class}.json",
            evidence_report(
                evidence_class=evidence_class,
                source_commit=commit,
                dirty=dirty,
                recorder=recorder,
                tool_versions=tool_versions,
                cleanup_status=cleanup_status,
                cleanup_ids=[cleanup_id],
            ),
        )
    return 0 if not dirty and cleanup_status == "succeeded" else 69


def snapshot_tree(root: Path) -> dict[str, str]:
    if not root.exists():
        return {}
    result: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        metadata = path.lstat()
        if stat.S_ISREG(metadata.st_mode):
            result[relative] = sha256_file(path)
        elif stat.S_ISDIR(metadata.st_mode):
            result[relative + "/"] = "directory"
        elif stat.S_ISLNK(metadata.st_mode):
            result[relative] = "symlink:" + os.readlink(path)
        else:
            result[relative] = f"mode:{metadata.st_mode}"
    return result


def doctor_command(args: argparse.Namespace) -> int:
    root = Path(args.source_root).resolve()
    hostwright = safe_file(args.hostwright, executable=True)
    container = resolved_executable(args.container, "container")
    state = Path(args.state_db)
    if not state.is_absolute():
        raise QualificationBlocked("doctor state database must be absolute")
    output = safe_new_directory(args.output_dir)
    recorder = Recorder()
    commit, dirty = source_truth(root)
    version = run([hostwright, "--version"], "read installed Hostwright version", recorder=recorder).stdout.strip()
    container_version = run([container, "--version"], "read Apple container version", recorder=recorder).stdout.strip()
    run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=4", hostwright],
        "verify installed Hostwright code signature",
        recorder=recorder,
    )
    run(
        [
            "/usr/bin/codesign",
            "--verify",
            "--verbose=4",
            "-R=notarized",
            "--check-notarization",
            hostwright,
        ],
        "check installed Hostwright notarization",
        recorder=recorder,
    )
    state_root = state.parent
    files_before = snapshot_tree(state_root)
    inventory_before, _ = inventory(container, recorder, "observe Apple inventory before doctor")
    result = run(
        [hostwright, "doctor", "--state-db", state, "--json"],
        f"run signed-install doctor expecting {args.expect}",
        expected={args.expect_exit},
        recorder=recorder,
    )
    report = json_output(result, "doctor")
    recorder.assertion("doctor schema is version 2", report.get("schemaVersion") == 2)
    recorder.assertion("doctor returned expected readiness", report.get("readiness") == args.expect)
    inventory_after, _ = inventory(container, recorder, "observe Apple inventory after doctor")
    files_after = snapshot_tree(state_root)
    recorder.assertion("doctor does not mutate state files", files_before == files_after)
    recorder.assertion("doctor does not mutate Apple inventory", inventory_before == inventory_after)
    write_json(
        output / "doctor-qualification-details.json",
        {
            "commands": recorder.details,
            "expectedReadiness": args.expect,
            "observedReadiness": report.get("readiness"),
            "stateTreeBeforeSHA256": sha256_bytes(canonical_json(files_before)),
            "stateTreeAfterSHA256": sha256_bytes(canonical_json(files_after)),
            "inventoryBeforeSHA256": inventory_before,
            "inventoryAfterSHA256": inventory_after,
        },
    )
    tools = {"hostwright": version, "container": container_version, "python": platform.python_version()}
    for evidence_class in ["live-runtime", "security-assessment"]:
        write_json(
            output / f"doctor-{args.expect}-{evidence_class}.json",
            evidence_report(
                evidence_class=evidence_class,
                source_commit=commit,
                dirty=dirty,
                recorder=recorder,
                tool_versions=tools,
                cleanup_status="succeeded",
                cleanup_ids=[f"doctor-{args.expect}-{commit[:12]}"],
            ),
        )
    return 0 if not dirty else 69


def boot_fingerprint() -> str:
    return run(["/usr/sbin/sysctl", "-n", "kern.boottime"], "read boot fingerprint").stdout.strip()


def power_prepare(args: argparse.Namespace) -> int:
    if os.environ.get("HOSTWRIGHT_DISPOSABLE_VM") != "1":
        raise QualificationBlocked("set HOSTWRIGHT_DISPOSABLE_VM=1 only inside the disposable qualification VM")
    hostwright = safe_file(args.hostwright, executable=True)
    manifest = safe_file(args.manifest)
    record = Path(args.record)
    if not record.is_absolute() or record.exists():
        raise QualificationBlocked("power-loss record must be an absent absolute path")
    record.parent.mkdir(mode=0o700, parents=False, exist_ok=False)
    state = record.parent / "state.sqlite"
    run([hostwright, "status", manifest, "--state-db", state, "--output", "json"], "seed VM power-loss state")
    integrity = json_output(
        run([hostwright, "state", "integrity", "--state-db", state, "--json"], "verify pre-cut state"),
        "pre-cut state integrity",
    )
    if integrity.get("health") != "healthy":
        raise QualificationFailure("pre-cut state is not healthy")
    acknowledged_rows = authoritative_row_hashes(state)
    if not acknowledged_rows:
        raise QualificationFailure("pre-cut state contains no authoritative rows to verify")
    workspace_id = str(uuid.uuid4())
    document = {
        "schemaVersion": 1,
        "workspaceID": workspace_id,
        "bootFingerprint": boot_fingerprint(),
        "stateDatabase": str(state),
        "hostwright": str(hostwright),
        "hostwrightSHA256": sha256_file(hostwright),
        "manifest": str(manifest),
        "manifestSHA256": sha256_file(manifest),
        "preCutDatabaseSHA256": integrity.get("databaseSHA256"),
        "preCutAuthoritativeRowHashes": acknowledged_rows,
        "lastAcknowledgedDatabaseSHA256": integrity.get("databaseSHA256"),
        "lastAcknowledgedAuthoritativeRowHashes": acknowledged_rows,
        "lastAcknowledgedIteration": 0,
        "preparedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    write_json(record, document)
    fsync_directory(record.parent)
    if not args.arm:
        print("Prepared. Re-run with --arm under the external VM controller, then hard-stop the VM while writes are active.")
        return 69
    iteration = 0
    while True:
        iteration += 1
        run(
            [hostwright, "status", manifest, "--state-db", state, "--output", "json"],
            f"power-loss active write {iteration}",
            timeout=120,
        )
        acknowledged_integrity = json_output(
            run(
                [hostwright, "state", "integrity", "--state-db", state, "--json"],
                f"verify acknowledged power-loss state {iteration}",
            ),
            f"acknowledged power-loss state {iteration}",
        )
        if acknowledged_integrity.get("health") != "healthy":
            raise QualificationFailure("an acknowledged power-loss state is not healthy")
        acknowledged_rows = authoritative_row_hashes(state)
        if not acknowledged_rows:
            raise QualificationFailure("an acknowledged power-loss state has no authoritative rows")
        document.update(
            {
                "lastAcknowledgedDatabaseSHA256": acknowledged_integrity.get("databaseSHA256"),
                "lastAcknowledgedAuthoritativeRowHashes": acknowledged_rows,
                "lastAcknowledgedIteration": iteration,
                "lastAcknowledgedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace(
                    "+00:00", "Z"
                ),
            }
        )
        replace_json(record, document)


def cleanup_power_workspace(record: Path, state: Path) -> None:
    parent = record.parent
    metadata = parent.lstat()
    if (not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode)
            or metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700):
        raise QualificationFailure("power-loss workspace ownership or mode changed")
    digest = hashlib.sha256(str(state).encode()).digest()[:8].hex()
    allowed = {
        record.name,
        state.name,
        state.name + "-journal",
        state.name + "-shm",
        state.name + "-wal",
        f".hostwright-{digest}-access-v1.lock",
    }
    entries = list(parent.iterdir())
    unexpected = sorted(path.name for path in entries if path.name not in allowed)
    if unexpected:
        raise QualificationFailure(
            "power-loss cleanup found unexpected workspace entries: " + ", ".join(unexpected)
        )
    for path in entries:
        entry = path.lstat()
        if (not stat.S_ISREG(entry.st_mode) or stat.S_ISLNK(entry.st_mode)
                or entry.st_uid != os.geteuid() or entry.st_nlink != 1):
            raise QualificationFailure(
                f"power-loss cleanup refused unsafe entry: {path.name}"
            )
    for path in entries:
        path.unlink()
    parent.rmdir()
    if parent.exists():
        raise QualificationFailure("power-loss workspace cleanup was incomplete")


def power_verify(args: argparse.Namespace) -> int:
    if os.environ.get("HOSTWRIGHT_DISPOSABLE_VM") != "1":
        raise QualificationBlocked("power-loss verification requires the disposable VM marker")
    root = Path(args.source_root).resolve()
    record = safe_file(args.record)
    document = json.loads(record.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != 1:
        raise QualificationFailure("power-loss record schema is unsupported")
    hostwright = safe_file(str(document.get("hostwright", "")), executable=True)
    state = safe_file(str(document.get("stateDatabase", "")))
    manifest = safe_file(str(document.get("manifest", "")))
    if state.parent != record.parent:
        raise QualificationFailure("power-loss state is outside the owned qualification workspace")
    if sha256_file(hostwright) != document.get("hostwrightSHA256"):
        raise QualificationFailure("Hostwright executable changed across the power-loss test")
    if sha256_file(manifest) != document.get("manifestSHA256"):
        raise QualificationFailure("power-loss manifest changed across the test")
    try:
        workspace_id = str(uuid.UUID(str(document.get("workspaceID", ""))))
    except ValueError as error:
        raise QualificationFailure("power-loss workspace identity is invalid") from error
    current_boot = boot_fingerprint()
    if current_boot == document.get("bootFingerprint"):
        raise QualificationBlocked("boot fingerprint did not change; an abrupt VM power cycle was not observed")
    output_candidate = Path(args.output_dir).resolve()
    if output_candidate == record.parent or output_candidate.is_relative_to(record.parent):
        raise QualificationBlocked("power-loss evidence output must be outside the cleanup workspace")
    output = safe_new_directory(args.output_dir)
    recorder = Recorder()
    commit, dirty = source_truth(root)
    integrity = json_output(
        run(
            [hostwright, "state", "integrity", "--state-db", state, "--json"],
            "verify state after abrupt VM power cycle",
            recorder=recorder,
        ),
        "post-cut state integrity",
    )
    recorder.assertion("post-cut state is healthy", integrity.get("health") == "healthy")
    post_cut_rows = authoritative_row_hashes(state)
    pre_cut_rows = document.get("preCutAuthoritativeRowHashes")
    last_acknowledged_rows = document.get("lastAcknowledgedAuthoritativeRowHashes")
    recorder.assertion(
        "power-loss record contains authoritative acknowledged states",
        isinstance(pre_cut_rows, dict)
        and bool(pre_cut_rows)
        and isinstance(last_acknowledged_rows, dict)
        and bool(last_acknowledged_rows),
    )
    recorder.assertion(
        "post-cut authoritative rows match a fully acknowledged state",
        bool(post_cut_rows)
        and post_cut_rows in [pre_cut_rows, last_acknowledged_rows],
        "post-cut state differs from both the prepared and last durably acknowledged states",
    )
    run(
        [hostwright, "status", manifest, "--state-db", state, "--output", "json"],
        "verify state remains writable after abrupt VM power cycle",
        recorder=recorder,
    )
    final_integrity = json_output(
        run(
            [hostwright, "state", "integrity", "--state-db", state, "--json"],
            "verify final post-cut integrity",
            recorder=recorder,
        ),
        "final post-cut integrity",
    )
    recorder.assertion("final post-cut state is healthy", final_integrity.get("health") == "healthy")
    cleanup_power_workspace(record, state)
    report = evidence_report(
        evidence_class="resilience-chaos",
        source_commit=commit,
        dirty=dirty,
        recorder=recorder,
        tool_versions={
            "hostwright": run([hostwright, "--version"], "read Hostwright version").stdout.strip(),
            "python": platform.python_version(),
        },
        cleanup_status="succeeded",
        cleanup_ids=[workspace_id],
    )
    write_json(output / "sqlite-abrupt-power-resilience-chaos.json", report)
    write_json(
        output / "sqlite-abrupt-power-details.json",
        {
            "commands": recorder.details,
            "preCutBootFingerprintSHA256": sha256_bytes(str(document["bootFingerprint"]).encode()),
            "postCutBootFingerprintSHA256": sha256_bytes(current_boot.encode()),
            "preCutDatabaseSHA256": document.get("preCutDatabaseSHA256"),
            "lastAcknowledgedDatabaseSHA256": document.get("lastAcknowledgedDatabaseSHA256"),
            "lastAcknowledgedIteration": document.get("lastAcknowledgedIteration"),
            "preCutAuthoritativeRowHashes": pre_cut_rows,
            "lastAcknowledgedAuthoritativeRowHashes": last_acknowledged_rows,
            "postCutAuthoritativeRowHashes": post_cut_rows,
            "postCutDatabaseSHA256": final_integrity.get("databaseSHA256"),
        },
    )
    return 0 if not dirty else 69


def copy_release(source: Path, destination: Path) -> None:
    shutil.copytree(source, destination, symlinks=True)
    for path in destination.iterdir():
        if path.name == "release-evidence.json":
            os.chmod(path, 0o600)
        elif path.is_file():
            os.chmod(path, 0o644)


def verify_release_command(args: argparse.Namespace) -> int:
    root = Path(args.source_root).resolve()
    dist = safe_file(args.hostwright_dist, executable=True)
    gh = resolved_executable(args.gh, "gh")
    output = safe_new_directory(args.output_dir)
    commit, dirty = source_truth(root)
    recorder = Recorder()
    work = Path(tempfile.mkdtemp(prefix="hostwright-phase02-public-release-"))
    os.chmod(work, 0o700)
    download = work / "download"
    download.mkdir(mode=0o700)
    cleanup_status = "failed"
    try:
        run(
            [gh, "release", "download", args.tag, "--repo", args.repository, "--dir", download],
            "download immutable public release bytes",
            timeout=300,
            recorder=recorder,
        )
        evidence = download / "release-evidence.json"
        if evidence.exists():
            os.chmod(evidence, 0o600)
        release_only = work / "release"
        release_only.mkdir(mode=0o700)
        for path in download.iterdir():
            if path.name != "hostwright.rb":
                shutil.copy2(path, release_only / path.name, follow_symlinks=False)
        for path in release_only.iterdir():
            os.chmod(path, 0o600 if path.name == "release-evidence.json" else 0o644)
        manifest_path = safe_file(str(download / "release-manifest.json"))
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        recorder.assertion("release tag matches manifest", manifest.get("releaseTag") == args.tag)
        recorder.assertion("release source commit matches qualified source", manifest.get("sourceCommit") == commit)
        recorder.assertion(
            "release signer teams match independent policy",
            manifest.get("applicationSigner", {}).get("teamIdentifier") == args.team_id
            and manifest.get("installerSigner", {}).get("teamIdentifier") == args.team_id,
        )
        run(
            ["/usr/bin/shasum", "-a", "256", "-c", "SHA256SUMS"],
            "verify public SHA-256 inventory",
            recorder=recorder,
            cwd=download,
        )
        for content, signature in [
            ("release-manifest.json", "release-manifest.json.cms"),
            ("SHA256SUMS", "SHA256SUMS.cms"),
            ("provenance.intoto.json", "provenance.intoto.json.cms"),
            ("release-evidence.json", "release-evidence.json.cms"),
        ]:
            run(
                ["/usr/bin/security", "cms", "-D", "-i", download / signature, "-c", download / content, "-n", "-u", "6"],
                f"verify detached CMS for {content}",
                recorder=recorder,
            )
        run(
            [dist, "verify-release", "--release-dir", work / "release", "--team-id", args.team_id, "--format", "json"],
            "verify release with hostwright-dist",
            timeout=300,
            recorder=recorder,
        )
        archive = safe_file(str(download / manifest["archive"]["fileName"]))
        package = safe_file(str(download / manifest["package"]["fileName"]))
        formula = safe_file(str(download / "hostwright.rb"))
        for artifact, label in [(archive, "archive"), (package, "package"), (formula, "Homebrew formula")]:
            run(
                [gh, "attestation", "verify", artifact, "--repo", args.repository],
                f"verify GitHub attestation for {label}",
                timeout=120,
                recorder=recorder,
            )
        run(
            ["/usr/sbin/pkgutil", "--check-signature", package],
            "verify package installer signature",
            recorder=recorder,
        )
        run(
            ["/usr/sbin/spctl", "--assess", "--verbose=4", "--type", "install", package],
            "assess package with Gatekeeper",
            recorder=recorder,
        )

        tampered = work / "tampered"
        copy_release(work / "release", tampered)
        with (tampered / archive.name).open("ab") as handle:
            handle.write(b"phase02-tamper")
        run_rejection(
            [dist, "verify-release", "--release-dir", tampered, "--team-id", args.team_id, "--format", "json"],
            "reject tampered public artifact bytes",
            recorder,
            required_text="HW-DIST-001",
        )
        missing = work / "missing-sidecar"
        copy_release(work / "release", missing)
        (missing / "SHA256SUMS.cms").unlink()
        run_rejection(
            [dist, "verify-release", "--release-dir", missing, "--team-id", args.team_id, "--format", "json"],
            "reject missing release sidecar",
            recorder,
            required_text="HW-DIST-001",
        )
        mismatch = work / "mismatched-manifest"
        copy_release(work / "release", mismatch)
        with (mismatch / "release-manifest.json").open("ab") as handle:
            handle.write(b"\n")
        run_rejection(
            [dist, "verify-release", "--release-dir", mismatch, "--team-id", args.team_id, "--format", "json"],
            "reject mismatched release manifest",
            recorder,
            required_text="HW-DIST-001",
        )
        wrong_team = "AAAAAAAAAA" if args.team_id != "AAAAAAAAAA" else "BBBBBBBBBB"
        run_rejection(
            [dist, "verify-release", "--release-dir", work / "release", "--team-id", wrong_team, "--format", "json"],
            "reject wrong Developer Team ID",
            recorder,
            required_text="HW-DIST-001",
        )
        unattested = work / "unattested-artifact"
        unattested.write_bytes(os.urandom(32))
        run_rejection(
            [gh, "attestation", "verify", unattested, "--repo", args.repository],
            "reject artifact with no GitHub attestation",
            recorder,
        )
        details = {
            "commands": recorder.details,
            "repository": args.repository,
            "tag": args.tag,
            "sourceCommit": commit,
            "teamIdentifier": args.team_id,
            "publicArtifactSHA256": {
                path.name: sha256_file(path)
                for path in sorted(download.iterdir())
                if path.is_file()
            },
        }
        cleanup_status = "succeeded"
    finally:
        shutil.rmtree(work, ignore_errors=False)
        if work.exists():
            cleanup_status = "failed"

    write_json(output / "public-release-verification-details.json", details)
    versions = {
        "hostwright-dist": run([dist, "--version"], "read hostwright-dist version").stdout.strip(),
        "gh": run([gh, "--version"], "read GitHub CLI version").stdout.splitlines()[0],
        "python": platform.python_version(),
    }
    for evidence_class in ["distribution-artifact", "security-assessment"]:
        write_json(
            output / f"public-release-{evidence_class}.json",
            evidence_report(
                evidence_class=evidence_class,
                source_commit=commit,
                dirty=dirty,
                recorder=recorder,
                tool_versions=versions,
                cleanup_status=cleanup_status,
                cleanup_ids=[work.name],
            ),
        )
    return 0 if not dirty and cleanup_status == "succeeded" else 69


def self_test() -> int:
    recorder = Recorder()
    with tempfile.TemporaryDirectory(prefix="hostwright-phase02-harness-self-test-") as directory:
        root = Path(directory)
        database = root / "state.sqlite"
        connection = sqlite3.connect(database)
        connection.execute("CREATE TABLE values_table (id TEXT PRIMARY KEY, value TEXT NOT NULL)")
        connection.execute("INSERT INTO values_table VALUES ('one', 'value')")
        connection.commit()
        connection.close()
        hashes = canonical_row_hashes(database)
        recorder.assertion("canonical SQLite row hashing", hashes["values_table"]["rows"] == 1)
        false_result = run_rejection(["/usr/bin/false"], "expected rejection normalization", recorder)
        recorder.assertion("expected rejection preserves observed exit", false_result.exit_code != 0)
        report = evidence_report(
            evidence_class="unit-contract",
            source_commit="0123456789abcdef0123456789abcdef01234567",
            dirty=True,
            recorder=recorder,
            tool_versions={"python": platform.python_version()},
            cleanup_status="not-required",
            cleanup_ids=[],
        )
        if report["status"] != "blocked" or report["rawResults"]["blocked"] != 1:
            raise QualificationFailure("dirty evidence was not blocked")
        empty = Recorder()
        no_commands = evidence_report(
            evidence_class="live-runtime",
            source_commit="0123456789abcdef0123456789abcdef01234567",
            dirty=False,
            recorder=empty,
            tool_versions={"python": platform.python_version()},
            cleanup_status="not-required",
            cleanup_ids=[],
        )
        if no_commands["status"] != "blocked" or not no_commands["blockers"]:
            raise QualificationFailure("empty live evidence was not blocked")
        cleanup = Recorder()
        cleanup.assertion("completed qualification command", True)
        failed_cleanup = evidence_report(
            evidence_class="resilience-chaos",
            source_commit="0123456789abcdef0123456789abcdef01234567",
            dirty=False,
            recorder=cleanup,
            tool_versions={"python": platform.python_version()},
            cleanup_status="failed",
            cleanup_ids=["self-test-workspace"],
        )
        if failed_cleanup["status"] != "failed" or not failed_cleanup["failures"]:
            raise QualificationFailure("cleanup failure was reported as passing evidence")
    print(json.dumps({"kind": "phase02QualificationSelfTest", "passed": 6, "failed": 0}, sort_keys=True))
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="command", required=True)

    state = subcommands.add_parser("state", help="Run live state, migration, security, and resilience qualification")
    state.add_argument("--source-root", required=True)
    state.add_argument("--hostwright", required=True)
    state.add_argument("--prior-hostwright", required=True)
    state.add_argument("--manifest", required=True)
    state.add_argument("--container")
    state.add_argument("--output-dir", required=True)

    doctor = subcommands.add_parser("doctor", help="Qualify one real signed-install doctor readiness cell")
    doctor.add_argument("--source-root", required=True)
    doctor.add_argument("--hostwright", required=True)
    doctor.add_argument("--state-db", required=True)
    doctor.add_argument("--container")
    doctor.add_argument("--expect", choices=sorted(READINESS_VALUES), required=True)
    doctor.add_argument("--expect-exit", type=int, required=True)
    doctor.add_argument("--output-dir", required=True)

    power = subcommands.add_parser("sqlite-power-loss", help="Prepare or verify an externally power-cut disposable VM")
    power.add_argument("action", choices=["prepare", "verify"])
    power.add_argument("--source-root")
    power.add_argument("--hostwright")
    power.add_argument("--manifest")
    power.add_argument("--record", required=True)
    power.add_argument("--output-dir")
    power.add_argument("--arm", action="store_true")

    release = subcommands.add_parser("verify-release", help="Independently verify public release bytes and negative cases")
    release.add_argument("--source-root", required=True)
    release.add_argument("--hostwright-dist", required=True)
    release.add_argument("--repository", default="hostwright/hostwright")
    release.add_argument("--tag", required=True)
    release.add_argument("--team-id", required=True)
    release.add_argument("--gh")
    release.add_argument("--output-dir", required=True)

    subcommands.add_parser("self-test", help="Run deterministic harness contract tests")
    return result


def main() -> int:
    args = parser().parse_args()
    if args.command == "self-test":
        return self_test()
    if args.command == "state":
        return state_command(args)
    if args.command == "doctor":
        return doctor_command(args)
    if args.command == "verify-release":
        if not __import__("re").fullmatch(r"[A-Z0-9]{10}", args.team_id):
            raise QualificationBlocked("--team-id must be the exact public 10-character Developer Team ID")
        return verify_release_command(args)
    if args.command == "sqlite-power-loss":
        if args.action == "prepare":
            if not args.hostwright or not args.manifest:
                raise QualificationBlocked("power-loss prepare requires --hostwright and --manifest")
            return power_prepare(args)
        if not args.source_root or not args.output_dir:
            raise QualificationBlocked("power-loss verify requires --source-root and --output-dir")
        return power_verify(args)
    raise QualificationFailure("unsupported qualification command")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except QualificationBlocked as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        raise SystemExit(69)
    except QualificationFailure as error:
        print(f"FAILED: {error}", file=sys.stderr)
        raise SystemExit(1)
