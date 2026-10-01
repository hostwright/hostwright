#!/usr/bin/env python3
"""Compare an authenticated legacy SDK build with the current compile inputs."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess


KIND = "hostwright.swift-sdk-reuse-compatibility.v1"
WORKFLOW = ".github/workflows/runtime-ingredients.yml"
BUILDER = "scripts/release/build-static-swift-sdk.sh"
PINS = "scripts/release/runtime-swift-sources.json"
MATERIALIZER = "scripts/release/materialize-swift-sdk-sources.py"
BUILD_JOB = "source-built-swift-sdk"
BUILD_STEPS = (
    "Check out the exact main commit",
    "Reclaim unused hosted .NET SDK storage",
    "Install pinned Swift SDK build prerequisites",
    "Install the exact signed Swift bootstrap toolchain",
    "Materialize the exact Swift source revisions",
    "Build the source-pinned static Swift SDK",
)
OPTIONAL_PRE_BUILD_STEPS = {
    "Validate checkpoint input pairing": (
        "      - name: Validate checkpoint input pairing\n"
        "        shell: bash\n"
        "        env:\n"
        "          REQUESTED_CHECKPOINT_ATTEMPT: ${{ inputs.sdk_checkpoint_attempt }}\n"
        "        run: test -z \"$REQUESTED_CHECKPOINT_ATTEMPT\"\n"
    ),
}
BUILDER_END_MARKERS = (
    "printf '%s Capturing SDK source and build inputs\\n'",
    "printf '%s SDK compilation complete; ready for authenticated checkpoint\\n'",
)


def _git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.PIPE)


def _blob(repo, commit, name):
    return _git(repo, "show", f"{commit}:{name}")


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _tree_files(repo, commit, prefix):
    output = _git(repo, "ls-tree", "-r", "-z", commit, "--", prefix)
    result = {}
    for item in output.split(b"\0"):
        if not item:
            continue
        metadata, raw_name = item.split(b"\t", 1)
        mode, kind, _ = metadata.decode("ascii").split()
        name = raw_name.decode("utf-8", "strict")
        if kind != "blob" or mode not in ("100644", "100755"):
            raise ValueError("unsupported SDK build recipe file: " + name)
        result[name] = _blob(repo, commit, name)
    if prefix.endswith("patches/swift-sdk") and not result:
        raise ValueError("SDK source patches are missing")
    return result


def _builder_compile_prefix(data):
    text = data.decode("utf-8", "strict")
    matches = [marker for marker in BUILDER_END_MARKERS if text.count(marker) == 1]
    if len(matches) != 1:
        raise ValueError("SDK builder compile/evidence boundary is missing or ambiguous")
    return text.split(matches[0], 1)[0].encode("utf-8")


def _job_block(text):
    lines = text.splitlines(keepends=True)
    start_matches = [i for i, line in enumerate(lines) if line.rstrip("\n") == f"  {BUILD_JOB}:"]
    if len(start_matches) != 1:
        raise ValueError("SDK build job is missing or ambiguous")
    start = start_matches[0]
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[index]):
            end = index
            break
    return lines[start:end]


def _workflow_globals(text):
    lines = text.splitlines(keepends=True)
    globals_ = {}
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.rstrip("\n") == "jobs:":
            break
        if not line.strip() or line.lstrip().startswith("#"):
            index += 1
            continue
        match = re.fullmatch(r"([A-Za-z0-9_-]+):(?:\s*.*)?\n?", line)
        if not match:
            raise ValueError("unsupported top-level SDK workflow setting")
        key = match.group(1)
        if key in ("env", "defaults", "permissions"):
            if key in globals_:
                raise ValueError("duplicate top-level workflow setting: " + key)
            block = [line]
            index += 1
            while index < len(lines) and (lines[index].startswith("  ") or not lines[index].strip()):
                block.append(lines[index])
                index += 1
            globals_[key] = "".join(block)
            continue
        if key not in ("name", "on"):
            raise ValueError("unrecognized top-level SDK workflow setting: " + key)
        index += 1
        if key == "on":
            while index < len(lines) and (lines[index].startswith("  ") or not lines[index].strip()):
                index += 1
    if not any(line.rstrip("\n") == "jobs:" for line in lines):
        raise ValueError("SDK workflow jobs are missing")
    return globals_


def _workflow_compile_config(data):
    text = data.decode("utf-8", "strict")
    workflow_globals = _workflow_globals(text)
    lines = _job_block(text)
    allowed_fields = {"name", "if", "runs-on", "timeout-minutes", "outputs", "permissions", "env", "steps"}
    scalar = {}
    steps_at = None
    env_lines = []
    env_seen = False
    for index, line in enumerate(lines[1:], 1):
        if line == "    steps:\n":
            steps_at = index
            break
        match = re.match(r"^    ([A-Za-z0-9_-]+):(?:\s*(.*?)\s*)?$", line.rstrip("\n"))
        if not match:
            continue
        key, value = match.groups()
        if key not in allowed_fields:
            raise ValueError("unrecognized SDK build job setting: " + key)
        if key in ("runs-on", "timeout-minutes"):
            if key in scalar:
                raise ValueError("duplicate SDK build job setting: " + key)
            scalar[key] = value or ""
        if key == "env":
            if env_seen:
                raise ValueError("duplicate SDK build job setting: env")
            env_seen = True
            env_lines.append(line)
            cursor = index + 1
            while cursor < len(lines) and (lines[cursor].startswith("      ") or not lines[cursor].strip()):
                env_lines.append(lines[cursor])
                cursor += 1
    if steps_at is None or "runs-on" not in scalar:
        raise ValueError("SDK runner or build steps are missing")
    runner_index = next(i for i, line in enumerate(lines) if line.startswith("    runs-on:"))
    for line in lines[runner_index + 1:]:
        if line.startswith("      ") and line.strip():
            raise ValueError("multiline SDK runner configuration is unsupported")
        if line.startswith("    ") and not line.startswith("      "):
            break
    if not scalar["runs-on"].strip():
        raise ValueError("SDK runner or build steps are missing")

    step_lines = lines[steps_at + 1:]
    starts = [i for i, line in enumerate(step_lines) if line.startswith("      - name:")]
    if not starts or any(line.startswith("      - ") and not line.startswith("      - name:") for line in step_lines):
        raise ValueError("SDK workflow contains an unnamed step")
    found = []
    for position, start in enumerate(starts):
        end = starts[position + 1] if position + 1 < len(starts) else len(step_lines)
        block = step_lines[start:end]
        match = re.fullmatch(r"      - name: (.+)\n", block[0])
        if not match:
            raise ValueError("invalid SDK workflow step name")
        found.append((match.group(1), "".join(block)))

    names = [name for name, _ in found]
    build_index = names.index(BUILD_STEPS[-1]) if names.count(BUILD_STEPS[-1]) == 1 else -1
    if build_index < 0:
        raise ValueError("SDK build step is missing or ambiguous")
    prefix_names = names[:build_index + 1]
    optional_counts = {name: prefix_names.count(name) for name in OPTIONAL_PRE_BUILD_STEPS}
    if any(count > 1 for count in optional_counts.values()):
        raise ValueError("optional SDK workflow step is duplicated")
    for name, expected_block in OPTIONAL_PRE_BUILD_STEPS.items():
        for found_name, block in found[:build_index + 1]:
            if found_name == name and block != expected_block:
                raise ValueError("optional SDK workflow step contents changed")
    normalized = [name for name in prefix_names if name not in OPTIONAL_PRE_BUILD_STEPS]
    if normalized != list(BUILD_STEPS):
        raise ValueError("SDK compiler setup steps changed or an unreviewed step was added")
    selected = [block for name, block in found[:build_index + 1] if name in BUILD_STEPS]
    return {"workflowGlobals": workflow_globals, "runsOn": scalar["runs-on"],
            "timeoutMinutes": scalar.get("timeout-minutes"),
            "environment": "".join(env_lines), "steps": selected}


def _recipe(repo, commit):
    input_files = {
        MATERIALIZER: _blob(repo, commit, MATERIALIZER),
        PINS: _blob(repo, commit, PINS),
        "builder-compile-prefix": _builder_compile_prefix(_blob(repo, commit, BUILDER)),
    }
    input_files.update(_tree_files(repo, commit, "scripts/release/patches/swift-sdk"))
    config = _workflow_compile_config(_blob(repo, commit, WORKFLOW))
    input_hashes = {name: _sha(data) for name, data in sorted(input_files.items())}
    input_hashes["workflow-compile-config"] = _sha(
        json.dumps(config, sort_keys=True, separators=(",", ":")).encode())
    return {"sha256": _sha(json.dumps(input_hashes, sort_keys=True, separators=(",", ":")).encode()),
            "inputs": input_hashes, "workflow": config}


def _validate_records(records, pins):
    records = Path(records)
    if not records.is_absolute() or records.is_symlink() or not records.is_dir():
        raise ValueError("SDK reuse records must be a regular directory")
    revisions_path = records / "source-revisions.json"
    build_path = records / "build-inputs" / "build-inputs.json"
    for path in (revisions_path, build_path):
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(records.resolve()):
            raise ValueError("SDK source/build inventory is missing or unsafe")
    revisions = json.loads(revisions_path.read_text(encoding="utf-8"))
    build = json.loads(build_path.read_text(encoding="utf-8"))
    archive = records / "swift-static-sdk.tar.gz"
    if (revisions.get("kind") != "hostwright.swift-sdk-source-lock.v1"
            or build.get("kind") != "hostwright.swift-sdk-build-inputs.v1"
            or build.get("status") != "prepared-not-release-qualified"):
        raise ValueError("legacy SDK source/build inventory is incomplete")
    expected = {row["destination"]: row for row in pins}
    revision_rows = revisions.get("projects")
    build_rows = build.get("sourceProjects")
    if not isinstance(revision_rows, list) or not isinstance(build_rows, list):
        raise ValueError("legacy SDK source inventory is missing")
    revisions_by_destination = {row.get("destination"): row for row in revision_rows}
    builds_by_destination = {row.get("destination"): row for row in build_rows}
    if (len(revisions_by_destination) != len(revision_rows) or len(builds_by_destination) != len(build_rows)
            or set(expected) != set(revisions_by_destination) or set(expected) != set(builds_by_destination)):
        raise ValueError("legacy SDK source inventory differs from current pins")
    for destination, pin in expected.items():
        revision = revisions_by_destination[destination]
        build_row = builds_by_destination[destination]
        source = build_row.get("source", {})
        common = ("destination", "repository", "commit")
        identity = "swift-sdk/" + destination
        if (any(revision.get(key) != pin.get(key) for key in common)
                or revision.get("identity") != identity
                or build_row.get("identity") != identity
                or build_row.get("directory") != "source-trees/" + destination
                or source.get("commit") != pin["commit"] or source.get("tree") != revision.get("tree")):
            raise ValueError("legacy SDK source revision differs from current pins: " + destination)
    if not archive.is_file() or archive.is_symlink():
        raise ValueError("legacy SDK archive is missing")
    archive_hash = hashlib.sha256()
    with archive.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            archive_hash.update(block)
    if (build.get("sdkArchiveSHA256") != archive_hash.hexdigest()
            or build.get("sdkArchiveSizeBytes") != archive.stat().st_size):
        raise ValueError("legacy SDK archive differs from its source inventory")
    return {"projectCount": len(expected), "sdkArchiveSHA256": archive_hash.hexdigest()}


def compare(repo_root, producer_commit, source_commit, records=None):
    repo = Path(repo_root).resolve(strict=True)
    head = _git(repo, "rev-parse", "HEAD").decode().strip()
    if head != source_commit:
        raise ValueError("current checkout does not match the requested source commit")
    status = _git(repo, "status", "--porcelain=v1", "--untracked-files=all").decode()
    if status:
        raise ValueError("SDK reuse requires a clean current checkout")
    for commit in (producer_commit, source_commit):
        if not re.fullmatch(r"[a-f0-9]{40}", commit):
            raise ValueError("invalid SDK producer/source commit")
        _git(repo, "cat-file", "-e", f"{commit}^{{commit}}")
    ancestor = subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor",
                               producer_commit, source_commit], check=False)
    if ancestor.returncode != 0:
        raise ValueError("SDK producer commit is not an ancestor of the current source")
    old_recipe, new_recipe = _recipe(repo, producer_commit), _recipe(repo, source_commit)
    if old_recipe["sha256"] != new_recipe["sha256"]:
        raise ValueError("SDK compile inputs differ from the authenticated producer")
    pins = json.loads(_blob(repo, source_commit, PINS))
    if not isinstance(pins, list) or not pins:
        raise ValueError("current Swift source pins are missing")
    inventory = _validate_records(records, pins) if records is not None else None
    return {"kind": KIND, "status": "compatible-not-release-qualified",
            "producer": {"commit": producer_commit}, "sourceCommit": source_commit,
            "compileInputs": {"sha256": new_recipe["sha256"], "files": new_recipe["inputs"]},
            "sourceInventory": inventory}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--producer-commit", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--records", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    output = args.output
    if not output.is_absolute() or not output.parent.is_dir() or output.exists() or output.is_symlink():
        raise ValueError("SDK compatibility output must be a new absolute file")
    result = compare(args.repo_root, args.producer_commit, args.source_commit, args.records)
    with output.open("xb") as stream:
        stream.write((json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n").encode())


if __name__ == "__main__":
    main()
