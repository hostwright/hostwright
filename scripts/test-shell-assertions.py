#!/usr/bin/env python3
"""Check that release assertions also fail on the system macOS Bash."""
import json
from pathlib import Path
import re
import subprocess
import unittest
from integration_doctor import validate

ROOT = Path(__file__).resolve().parent.parent
INTEGRATION = ROOT / "scripts/integration.sh"


class ShellAssertionTests(unittest.TestCase):
    def test_integration_version_mismatch_stops_before_success(self):
        self.check_version("unexpected-version", 1, "")

    def test_integration_current_version_reaches_success(self):
        version = json.loads((ROOT / "contracts/v0.0.2/versions.json").read_text())["productVersion"]
        self.check_version(version, 0, "version accepted\n")

    def check_version(self, actual, expected_exit, expected_output):
        version = json.loads((ROOT / "contracts/v0.0.2/versions.json").read_text())["productVersion"]
        checks = [line for line in INTEGRATION.read_text().splitlines()
                  if line.startswith('[[ "$version" == "$golden_version" ]]')]
        self.assertEqual(len(checks), 1, "Expected one canonical integration version assertion")
        script = 'set -euo pipefail\nversion="$1"\ngolden_version="$2"\n' + checks[0]
        script += '\nprintf "version accepted\\n"\n'
        result = subprocess.run(["/bin/bash", "-c", script, "version-check", actual, version],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, expected_exit, result.stderr)
        self.assertEqual(result.stdout, expected_output)

    def test_release_assertions_have_explicit_failure_handling(self):
        paths = [INTEGRATION, ROOT / "scripts/release/capture-static-swift-sdk-evidence.sh"]
        paths.extend(sorted((ROOT / ".github/workflows").glob("*.yml")))
        unguarded = []
        for path in paths:
            if path.name == "runtime-ingredients.yml":
                # Preserve the pinned SDK recipe; its Linux runners use modern Bash.
                runners = re.findall(r"^\s*runs-on:\s*(\S+)\s*$", path.read_text(), re.M)
                self.assertTrue(runners and all(r.startswith("ubuntu-") for r in runners))
                continue
            # Join continued shell lines before checking standalone assertions.
            text = re.sub(r"\\\n\s*", " ", path.read_text())
            for number, line in enumerate(text.splitlines(), 1):
                if re.match(r"^\s*\[\[.*\]\]\s*$", line) or re.search(r"; do \[\[.*\]\]; done", line):
                    unguarded.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
        self.assertEqual(unguarded, [], "Unguarded compound assertions:\n" + "\n".join(unguarded))


class DoctorIntegrationTests(unittest.TestCase):
    def report(self):
        return {"schemaVersion": 2, "kind": "doctor", "hasFailures": True,
                "hasExternalConstraints": False, "checks": [
                    {"identifier": "stateIntegrity", "status": "ready"},
                    {"identifier": "signingTrust", "status": "blocked", "details": {
                        "codeSignature": "ad-hoc", "gatekeeper": "rejected", "developmentBuild": "false"}}]}

    def test_unsigned_source_build_is_rejected_by_doctor(self):
        validate(self.report(), 65)

    def test_unrelated_failure_is_not_tolerated(self):
        for status in ("blocked", "unsupported"):
            with self.subTest(status=status):
                report = self.report()
                report["checks"][0]["status"] = status
                with self.assertRaises(ValueError):
                    validate(report, 65)

    def test_invalid_signature_is_not_tolerated(self):
        report = self.report()
        report["checks"][1]["details"]["codeSignature"] = "invalid"
        with self.assertRaises(ValueError):
            validate(report, 65)

    def test_false_success_is_rejected(self):
        with self.assertRaises(ValueError):
            validate(self.report(), 0)

    def test_report_summary_must_match_checks(self):
        report = self.report()
        report["hasFailures"] = False
        with self.assertRaises(ValueError):
            validate(report, 65)

    def test_nonfailing_report_requires_matching_exit(self):
        for external in (False, True):
            with self.subTest(external=external):
                report = self.report()
                report["checks"][1]["status"] = "degraded"
                report["checks"][0]["status"] = "externally-constrained" if external else "ready"
                report.update(hasFailures=False, hasExternalConstraints=external)
                validate(report, 69 if external else 0)
                with self.assertRaises(ValueError):
                    validate(report, 65)


if __name__ == "__main__":
    unittest.main()
