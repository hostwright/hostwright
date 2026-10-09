"""Validate live doctor outcomes from the local source integration executable."""
import json
from pathlib import Path
import sys


def validate(report, exit_code):
    if report.get("schemaVersion") != 2 or report.get("kind") != "doctor":
        raise ValueError("Unexpected doctor report")
    checks = report.get("checks", [])
    statuses = {"ready", "degraded", "blocked", "unsupported", "externally-constrained"}
    if not checks or any(c.get("status") not in statuses for c in checks):
        raise ValueError("Missing or invalid doctor checks")
    identifiers = [c.get("identifier") for c in checks]
    if len(set(identifiers)) != len(identifiers) or "signingTrust" not in identifiers:
        raise ValueError("Missing or duplicate doctor check identifiers")
    failures = [c for c in checks if c["status"] in {"blocked", "unsupported"}]
    external = any(c["status"] == "externally-constrained" for c in checks)
    if report.get("hasFailures") is not bool(failures) or report.get("hasExternalConstraints") is not external:
        raise ValueError("Doctor summary disagrees with its checks")
    if failures:
        signing = next(c for c in checks if c["identifier"] == "signingTrust")
        details = signing.get("details", {})
        if not (exit_code == 65 and failures == [signing] and signing["status"] == "blocked"
                and details.get("codeSignature") in {"ad-hoc", "unsigned"}
                and details.get("gatekeeper") == "rejected"
                and details.get("developmentBuild") == "false"):
            raise ValueError("Unexpected doctor failure; only unsigned source-build trust rejection is expected")
    elif exit_code != (69 if external else 0):
        raise ValueError("Doctor exit code disagrees with its checks")


if __name__ == "__main__":
    validate(json.loads(Path(sys.argv[1]).read_text()), int(sys.argv[2]))
