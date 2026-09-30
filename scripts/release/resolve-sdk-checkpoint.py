#!/usr/bin/env python3
"""Resolve a checkpoint's immutable producer, including an earlier successful attempt."""
import json
import os
import re
import subprocess


REPO = "hostwright/hostwright"
WORKFLOW = ".github/workflows/runtime-ingredients.yml"


def number(value):
    if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]*", value):
        raise ValueError("checkpoint run and attempt must be positive integers")
    return int(value)


def resolve(environment):
    reuse_run = environment.get("REUSE_RUN", "")
    reuse_attempt = environment.get("REUSE_ATTEMPT", "")
    if bool(reuse_run) != bool(reuse_attempt):
        raise ValueError("checkpoint run and original attempt must be supplied together")
    if environment["GITHUB_REPOSITORY"] != REPO:
        raise ValueError("unexpected checkpoint repository")
    if reuse_run:
        run_id, attempt = number(reuse_run), number(reuse_attempt)
        result = subprocess.run(["gh", "api", f"repos/{REPO}/actions/runs/{run_id}"],
                                check=True, capture_output=True, text=True, timeout=60)
        run = json.loads(result.stdout)
        if (run.get("id") != run_id or run.get("repository", {}).get("full_name") != REPO
                or run.get("path", "").split("@", 1)[0] != WORKFLOW
                or run.get("head_branch") != "main" or run.get("event") != "workflow_dispatch"
                or type(run.get("run_attempt")) is not int or attempt > run["run_attempt"]):
            raise ValueError("checkpoint run does not match the trusted producer workflow")
        source = run.get("head_sha", "")
    else:
        run_id = number(environment["GITHUB_RUN_ID"])
        attempt = number(environment["BUILT_ATTEMPT"])
        source = environment["GITHUB_SHA"]
    if not isinstance(source, str) or not re.fullmatch(r"[a-f0-9]{40}", source):
        raise ValueError("checkpoint producer source commit is invalid")
    artifact_kind = "checkpoint"
    artifact_name = f"runtime-swift-sdk-checkpoint-{source}-{run_id}-{attempt}"
    if reuse_run:
        result = subprocess.run(["gh", "api", "--paginate", "--slurp",
                                f"repos/{REPO}/actions/runs/{run_id}/artifacts?per_page=100"],
                                check=True, capture_output=True, text=True, timeout=60)
        pages = json.loads(result.stdout)
        artifacts = [item for page in pages for item in page["artifacts"] if not item.get("expired", True)]
        sdk_name = f"runtime-swift-sdk-{source}-{run_id}-{attempt}"
        matches = [item for item in artifacts if item.get("name") == sdk_name]
        if matches:
            artifact_kind, artifact_name = "sdk", sdk_name
        else:
            matches = [item for item in artifacts if item.get("name") == artifact_name]
        if len(matches) != 1:
            raise ValueError("exact SDK artifact or checkpoint is missing, expired or ambiguous")
    return {"run-id": str(run_id), "producer-attempt": str(attempt), "source-commit": source,
            "artifact-kind": artifact_kind, "artifact-name": artifact_name}


if __name__ == "__main__":
    resolved = resolve(os.environ)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        for key, value in resolved.items():
            output.write(f"{key}={value}\n")
