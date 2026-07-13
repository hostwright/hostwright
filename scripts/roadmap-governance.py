#!/usr/bin/env python3
"""Validate the v0.0.2 roadmap and enforce evidence-gated closure."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "docs" / "roadmap" / "v0.0.2" / "issues.json"
REPOSITORY = "hostwright/hostwright"
RELEASE_LABEL = "roadmap:v0.0.2"
ASSIGNEE = "d3v07"
EVIDENCE_MARKER = "<!-- hostwright-evidence-gate:v1 -->"
EVIDENCE_CLASSES = [
    "unit-contract",
    "local-integration",
    "live-runtime",
    "hardware-benchmark",
    "distribution-artifact",
    "migration-upgrade",
    "security-assessment",
    "resilience-chaos",
    "multi-host",
    "interop-conformance",
    "ux-accessibility",
]
PHASE_SCHEDULE = [
    {"phase": phase, "targetDate": f"2026-07-{phase + 12:02d}"}
    for phase in range(1, 16)
]
CLOSURE_PATTERN = re.compile(
    r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+(?:hostwright/hostwright)?#(\d+)",
    re.IGNORECASE,
)


class GovernanceError(RuntimeError):
    pass


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GovernanceError(f"cannot read JSON {path}: {error}") from error
    if not isinstance(value, dict):
        raise GovernanceError(f"{path} must contain a JSON object")
    return value


def require(condition: bool, message: str) -> None:
    if not condition:
        raise GovernanceError(message)


def validate_manifest(path: Path) -> dict[str, Any]:
    document = load_json(path)
    require(document.get("schemaVersion") == 1, "roadmap schemaVersion must be 1")
    require(document.get("repository") == REPOSITORY, f"roadmap repository must be {REPOSITORY}")
    require(document.get("release") == "v0.0.2", "roadmap release must be v0.0.2")
    require(document.get("evidenceClasses") == EVIDENCE_CLASSES, "roadmap evidenceClasses must match the v0.0.2 verification constitution")

    milestone = document.get("milestone")
    require(isinstance(milestone, dict), "roadmap milestone must be an object")
    require(milestone.get("number") == 10, "v0.0.2 milestone number must be 10")
    require(milestone.get("dueOn") == "2026-07-27", "v0.0.2 due date must be 2026-07-27")
    require(
        document.get("phaseSchedule") == PHASE_SCHEDULE,
        "v0.0.2 phase schedule must run daily from 2026-07-13 through 2026-07-27",
    )

    issues = document.get("issues")
    require(isinstance(issues, list), "roadmap issues must be an array")
    require(len(issues) == 183, f"roadmap must contain 183 issues, found {len(issues)}")
    require(all(isinstance(issue, dict) for issue in issues), "every roadmap issue must be an object")

    numbers = [issue.get("number") for issue in issues]
    markers = [issue.get("marker") for issue in issues]
    require(all(isinstance(number, int) and number > 0 for number in numbers), "issue numbers must be positive integers")
    require(all(isinstance(marker, str) and marker for marker in markers), "issue markers must be non-empty strings")
    require(len(set(numbers)) == len(numbers), "roadmap issue numbers must be unique")
    require(len(set(markers)) == len(markers), "roadmap issue markers must be unique")

    masters = [issue for issue in issues if issue.get("kind") == "master"]
    epics = [issue for issue in issues if issue.get("kind") == "epic"]
    children = [issue for issue in issues if issue.get("kind") == "workstream"]
    require(len(masters) == 1, f"roadmap must contain one master, found {len(masters)}")
    require(len(epics) == 15, f"roadmap must contain 15 epics, found {len(epics)}")
    require(len(children) == 167, f"roadmap must contain 167 workstreams, found {len(children)}")
    require(document.get("counts") == {"master": 1, "epics": 15, "workstreams": 167, "total": 183}, "roadmap counts object is stale")

    master = masters[0]
    require(master.get("marker") == "MASTER", "master marker must be MASTER")
    require(master.get("phase") is None and master.get("child") is None and master.get("parent") is None, "master hierarchy is invalid")
    epic_by_phase = {epic.get("phase"): epic for epic in epics}
    require(set(epic_by_phase) == set(range(1, 16)), "epic phases must be exactly 1 through 15")

    for issue in issues:
        number = issue["number"]
        labels = issue.get("labels")
        assignees = issue.get("assignees")
        require(isinstance(issue.get("title"), str) and issue["title"].strip(), f"issue #{number} has no title")
        require(issue.get("url") == f"https://github.com/{REPOSITORY}/issues/{number}", f"issue #{number} URL is invalid")
        require(isinstance(labels, list) and RELEASE_LABEL in labels, f"issue #{number} lacks {RELEASE_LABEL}")
        require(isinstance(assignees, list) and ASSIGNEE in assignees, f"issue #{number} lacks assignee {ASSIGNEE}")

    for phase, epic in epic_by_phase.items():
        require(epic.get("marker") == f"P{phase:02d}", f"phase {phase} epic marker is invalid")
        require(epic.get("parent") == master["number"], f"phase {phase} epic parent is invalid")
        require(epic.get("child") is None, f"phase {phase} epic child field must be null")

        phase_children = sorted(
            (child for child in children if child.get("phase") == phase),
            key=lambda child: child.get("child", 0),
        )
        require(phase_children, f"phase {phase} has no child workstreams")
        expected_indices = list(range(1, len(phase_children) + 1))
        require([child.get("child") for child in phase_children] == expected_indices, f"phase {phase} child indices are not contiguous")
        for child in phase_children:
            index = child["child"]
            require(child.get("marker") == f"P{phase:02d}-C{index:02d}", f"issue #{child['number']} marker is invalid")
            require(child.get("parent") == epic["number"], f"issue #{child['number']} parent is invalid")

    return document


def labels_from(payload: dict[str, Any], object_name: str) -> set[str]:
    item = payload.get(object_name)
    if not isinstance(item, dict):
        return set()
    labels = item.get("labels", [])
    return {
        label.get("name")
        for label in labels
        if isinstance(label, dict) and isinstance(label.get("name"), str)
    }


def parse_evidence_fields(body: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for match in re.finditer(r"(?m)^- ([A-Za-z0-9 /_-]+):\s*(.*?)\s*$", body):
        fields[match.group(1).strip().lower()] = match.group(2).strip()
    return fields


def declared_evidence_classes(body: str) -> tuple[set[str], list[str]]:
    declarations = re.findall(r"(?im)^Required evidence classes:\s*(.+)$", body)
    if len(declarations) != 1:
        return set(), [f"expected one required evidence declaration, found {len(declarations)}"]
    declared = set(re.findall(r"[a-z]+(?:-[a-z]+)+", declarations[0]))
    unknown = declared - set(EVIDENCE_CLASSES)
    errors: list[str] = []
    if not declared:
        errors.append("required evidence declaration is empty")
    if unknown:
        errors.append("unknown evidence classes: " + ", ".join(sorted(unknown)))
    return declared, errors


def evidence_errors(body: str, required_classes: set[str] | None = None) -> list[str]:
    errors: list[str] = []
    if EVIDENCE_MARKER not in body:
        errors.append(f"missing {EVIDENCE_MARKER}")
    if "## Final Evidence Gate" not in body:
        errors.append("missing '## Final Evidence Gate'")

    fields = parse_evidence_fields(body)
    required = [
        "commit",
        "dirty",
        "os/build/architecture/hardware",
        "runtime/framework/tool versions",
        "commands and raw outcomes",
        "failures",
        "blockers",
        "cleanup and exact resource identifiers",
        "required evidence artifacts",
        "documentation and compatibility matrix updates",
    ]
    for field in required:
        if not fields.get(field):
            errors.append(f"missing or empty evidence field: {field}")

    commit = fields.get("commit", "")
    if commit and re.fullmatch(r"[a-f0-9]{40}", commit) is None:
        errors.append("commit must be a full lowercase 40-character Git SHA")
    if fields.get("dirty", "").lower() != "false":
        errors.append("Dirty must be false")
    if fields.get("failures", "").lower() not in {"none", "[]", "0"}:
        errors.append("Failures must be none")
    if fields.get("blockers", "").lower() not in {"none", "[]", "0"}:
        errors.append("Blockers must be none")
    forbidden = re.compile(
        r"\b(?:[1-9][0-9]*\s+blocked|blocked\s*[:=]\s*[1-9][0-9]*|status\s*[:=]\s*blocked|skipped|mock-only|fixture-only|cleanup failed)\b",
        re.IGNORECASE,
    )
    if forbidden.search(fields.get("commands and raw outcomes", "")) or forbidden.search(fields.get("required evidence artifacts", "")):
        errors.append("final evidence cannot be blocked, skipped, mock-only, fixture-only, or cleanup-failed")
    if required_classes:
        artifacts = fields.get("required evidence artifacts", "")
        missing = sorted(evidence_class for evidence_class in required_classes if evidence_class not in artifacts)
        if missing:
            errors.append("required evidence artifacts omit: " + ", ".join(missing))
    return errors


def check_pull_request(event_path: Path, manifest_path: Path) -> None:
    document = validate_manifest(manifest_path)
    event = load_json(event_path)
    pull_request = event.get("pull_request")
    require(isinstance(pull_request, dict), "event has no pull_request object")
    body = pull_request.get("body") or ""
    require(isinstance(body, str), "pull request body must be text")

    roadmap_numbers = {issue["number"] for issue in document["issues"]}
    closure_numbers = {int(number) for number in CLOSURE_PATTERN.findall(body)} & roadmap_numbers
    if not closure_numbers:
        print("roadmap governance: no roadmap closure keywords; intermediate PR is allowed")
        return

    errors: list[str] = []
    if "status:verification" not in labels_from(event, "pull_request"):
        errors.append("closing a roadmap issue requires the PR label status:verification")
    errors.extend(evidence_errors(body))
    if errors:
        issues = ", ".join(f"#{number}" for number in sorted(closure_numbers))
        raise GovernanceError(f"closure requested for {issues}: " + "; ".join(errors))
    print("roadmap governance: final PR evidence gate passed for " + ", ".join(f"#{number}" for number in sorted(closure_numbers)))


def github_request(method: str, path: str, token: str, payload: dict[str, Any] | None = None) -> Any:
    url = f"https://api.github.com/repos/{REPOSITORY}{path}"
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(url, data=body, method=method)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("X-GitHub-Api-Version", "2022-11-28")
    if body is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            response_body = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise GovernanceError(f"GitHub API {method} {path} failed with {error.code}: {detail}") from error
    except urllib.error.URLError as error:
        raise GovernanceError(f"GitHub API {method} {path} failed: {error}") from error
    if not response_body:
        return None
    return json.loads(response_body)


def github_issue_comments(number: int, token: str) -> list[dict[str, Any]]:
    comments: list[dict[str, Any]] = []
    for page in range(1, 101):
        batch = github_request("GET", f"/issues/{number}/comments?per_page=100&page={page}", token)
        require(isinstance(batch, list), f"GitHub comments for issue #{number} were not an array")
        comments.extend(comment for comment in batch if isinstance(comment, dict))
        if len(batch) < 100:
            return comments
    raise GovernanceError(f"issue #{number} has more comments than the closure gate can safely inspect")


def enforce_issue_closure(event_path: Path, manifest_path: Path, token: str) -> None:
    document = validate_manifest(manifest_path)
    event = load_json(event_path)
    require(event.get("action") == "closed", "issue closure enforcement requires a closed event")
    issue = event.get("issue")
    require(isinstance(issue, dict) and isinstance(issue.get("number"), int), "event has no issue number")
    number = issue["number"]
    roadmap_by_number = {record["number"]: record for record in document["issues"]}
    if number not in roadmap_by_number:
        print(f"roadmap governance: issue #{number} is outside the v0.0.2 roadmap")
        return

    errors: list[str] = []
    if "status:verification" not in labels_from(event, "issue"):
        errors.append("issue lacks status:verification")
    issue_body = issue.get("body") or ""
    require(isinstance(issue_body, str), f"issue #{number} body must be text")
    required_classes, declaration_errors = declared_evidence_classes(issue_body)
    errors.extend(declaration_errors)

    comments = github_issue_comments(number, token)
    evidence_bodies = [
        comment.get("body", "")
        for comment in comments
        if isinstance(comment, dict) and EVIDENCE_MARKER in (comment.get("body") or "")
    ]
    if not evidence_bodies:
        errors.append("no final evidence comment was found")
    else:
        errors.extend(evidence_errors(evidence_bodies[-1], required_classes=required_classes))

    children = [record for record in document["issues"] if record.get("parent") == number]
    open_children: list[int] = []
    for child in children:
        current = github_request("GET", f"/issues/{child['number']}", token)
        if not isinstance(current, dict) or current.get("state") != "closed":
            open_children.append(child["number"])
    if open_children:
        errors.append("open child issues: " + ", ".join(f"#{child}" for child in open_children))

    if not errors:
        print(f"roadmap governance: issue #{number} closure evidence passed")
        return

    github_request("PATCH", f"/issues/{number}", token, {"state": "open"})
    reason_lines = "\n".join(f"- {error}" for error in errors)
    comment = (
        "<!-- hostwright-governance:reopen:v1 -->\n"
        "This roadmap issue was reopened because the executable closure gate did not pass:\n\n"
        f"{reason_lines}\n\n"
        "Add the `status:verification` label, close every child, and post a complete clean final evidence comment before closing again."
    )
    github_request("POST", f"/issues/{number}/comments", token, {"body": comment})
    raise GovernanceError(f"issue #{number} was reopened: " + "; ".join(errors))


def valid_evidence_body(issue_number: int) -> str:
    return f"""## Final Evidence Gate

Closes #{issue_number}

{EVIDENCE_MARKER}

- Commit: 0123456789abcdef0123456789abcdef01234567
- Dirty: false
- OS/build/architecture/hardware: macOS 26.5 / arm64 / test Mac
- Runtime/framework/tool versions: container 1.1.0; Swift 6.3
- Commands and raw outcomes: 12 executed, 12 passed, 0 failed, 0 blocked
- Failures: none
- Blockers: none
- Cleanup and exact resource identifiers: not required for this contract check
- Required evidence artifacts: unit-contract report passed
- Documentation and compatibility matrix updates: reviewed and current
"""


def self_test(manifest_path: Path) -> None:
    document = validate_manifest(manifest_path)
    target = next(issue["number"] for issue in document["issues"] if issue["kind"] == "workstream")
    valid_event = {
        "pull_request": {
            "body": valid_evidence_body(target),
            "labels": [{"name": "status:verification"}],
        }
    }
    invalid_event = json.loads(json.dumps(valid_event))
    invalid_event["pull_request"]["body"] = invalid_event["pull_request"]["body"].replace("Dirty: false", "Dirty: true")

    declared, declaration_errors = declared_evidence_classes(
        "Required evidence classes: unit-contract, local-integration."
    )
    require(declared == {"unit-contract", "local-integration"} and not declaration_errors, "valid evidence declaration failed")
    _, unknown_errors = declared_evidence_classes("Required evidence classes: unit-contract, invented-evidence.")
    require(any("unknown evidence classes" in error for error in unknown_errors), "unknown evidence class did not fail")
    missing_artifact_errors = evidence_errors(valid_evidence_body(target), required_classes={"migration-upgrade"})
    require(any("required evidence artifacts omit" in error for error in missing_artifact_errors), "missing required artifact did not fail")

    import tempfile

    with tempfile.TemporaryDirectory(prefix="hostwright-roadmap-") as directory:
        valid_path = Path(directory) / "valid.json"
        invalid_path = Path(directory) / "invalid.json"
        valid_path.write_text(json.dumps(valid_event), encoding="utf-8")
        invalid_path.write_text(json.dumps(invalid_event), encoding="utf-8")
        check_pull_request(valid_path, manifest_path)
        try:
            check_pull_request(invalid_path, manifest_path)
        except GovernanceError as error:
            require("Dirty must be false" in str(error), "invalid dirty evidence did not fail for the expected reason")
        else:
            raise GovernanceError("invalid dirty evidence unexpectedly passed")
    print("roadmap governance: self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["validate", "check-pr", "enforce-closure", "self-test"])
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--event", type=Path, default=Path(os.environ.get("GITHUB_EVENT_PATH", "")))
    arguments = parser.parse_args()

    try:
        if arguments.command == "validate":
            document = validate_manifest(arguments.manifest)
            print(f"roadmap governance: validated {len(document['issues'])} v0.0.2 issues")
        elif arguments.command == "check-pr":
            require(str(arguments.event), "--event or GITHUB_EVENT_PATH is required")
            check_pull_request(arguments.event, arguments.manifest)
        elif arguments.command == "enforce-closure":
            require(str(arguments.event), "--event or GITHUB_EVENT_PATH is required")
            token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
            require(bool(token), "GH_TOKEN or GITHUB_TOKEN is required")
            enforce_issue_closure(arguments.event, arguments.manifest, token or "")
        else:
            self_test(arguments.manifest)
    except GovernanceError as error:
        print(f"roadmap governance failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
