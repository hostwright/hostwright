#!/usr/bin/env python3
"""Tests for source-bound reuse of a completed legacy SDK artifact."""

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "verify_sdk_reuse", Path(__file__).with_name("verify-sdk-reuse.py"))
REUSE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REUSE)


class VerifySDKReuseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "SDK reuse tests")
        self.git("config", "user.email", "sdk-reuse@example.invalid")
        self._write_recipe()
        self.producer = self.commit("original producer")
        self._write_recipe(evidence_only=True)
        self.consumer = self.commit("evidence split")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def write(self, name, data):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)

    @staticmethod
    def workflow(extra_before="", extra_after="", global_env=""):
        return f'''name: SDK fixture
on:
  workflow_dispatch:
{global_env}jobs:
  source-built-swift-sdk:
    name: {"Build and checkpoint" if extra_before else "Build and attest"}
    if: ${{{{ github.event_name == 'workflow_dispatch' }}}}
    runs-on: ubuntu-24.04-arm
    timeout-minutes: 360
    permissions:
      contents: read
    steps:
{extra_before}      - name: Check out the exact main commit
        uses: actions/checkout@1111111111111111111111111111111111111111
      - name: Reclaim unused hosted .NET SDK storage
        shell: bash
        run: test "$RUNNER_ENVIRONMENT" = github-hosted
      - name: Install pinned Swift SDK build prerequisites
        shell: bash
        run: apt-get install --yes cmake ninja-build
      - name: Install the exact signed Swift bootstrap toolchain
        shell: bash
        run: swiftly install 6.3.0
      - name: Materialize the exact Swift source revisions
        shell: bash
        run: python3 scripts/release/materialize-swift-sdk-sources.py --root /workspace/sources
      - name: Build the source-pinned static Swift SDK
        shell: bash
        run: scripts/release/build-static-swift-sdk.sh --root /workspace/sources
{extra_after}'''

    def _write_recipe(self, *, evidence_only=False, changed_compile=False, global_env=""):
        pins = [{"destination": "swift-project", "repository": "https://example.invalid/swift.git",
                 "commit": "a" * 40}]
        self.write("scripts/release/runtime-swift-sources.json", json.dumps(pins) + "\n")
        self.write("scripts/release/materialize-swift-sdk-sources.py", "print('materialize exact pins')\n")
        self.write("scripts/release/patches/swift-sdk/foundation.patch", "reviewed patch\n")
        builder = "#!/bin/bash\nset -euo pipefail\njobs=3\n"
        builder += "jobs=4\n" if changed_compile else ""
        builder += "cp product.tar.gz sdk.tar.gz\n"
        if evidence_only:
            builder += "printf '%s SDK compilation complete; ready for authenticated checkpoint\\n'\n"
        else:
            builder += "printf '%s Capturing SDK source and build inputs\\n'\n"
        builder += "python3 capture-evidence.py\n"
        self.write("scripts/release/build-static-swift-sdk.sh", builder)
        before = ("      - name: Validate checkpoint input pairing\n"
                  "        shell: bash\n"
                  "        env:\n"
                  "          REQUESTED_CHECKPOINT_ATTEMPT: ${{ inputs.sdk_checkpoint_attempt }}\n"
                  "        run: test -z \"$REQUESTED_CHECKPOINT_ATTEMPT\"\n") if evidence_only else ""
        after = ("      - name: Capture the reusable SDK build checkpoint\n"
                 "        run: python3 sdk-build-checkpoint.py\n") if evidence_only else (
                 "      - name: Attest the source-built SDK and retained build records\n"
                 "        uses: actions/attest@1111111111111111111111111111111111111111\n")
        self.write(".github/workflows/runtime-ingredients.yml",
                   self.workflow(before, after, global_env))

    def records(self, *, wrong_pin=False):
        root = Path(self.temporary.name) / ("records-bad" if wrong_pin else "records")
        archive = root / "swift-static-sdk.tar.gz"
        archive.parent.mkdir(parents=True, exist_ok=True)
        archive.write_bytes(b"authenticated sdk fixture")
        pin = json.loads((self.repo / "scripts/release/runtime-swift-sources.json").read_text())[0]
        tree = "b" * 40
        source_commit = "c" * 40 if wrong_pin else pin["commit"]
        revisions = {"kind": "hostwright.swift-sdk-source-lock.v1", "projects": [
            dict(identity="swift-sdk/swift-project", destination="swift-project",
                 repository=pin["repository"], commit=source_commit, tree=tree)]}
        (root / "source-revisions.json").write_text(json.dumps(revisions))
        project = dict(identity="swift-sdk/swift-project", destination="swift-project",
                       directory="source-trees/swift-project", source=dict(commit=source_commit, tree=tree))
        build_inputs = {"kind": "hostwright.swift-sdk-build-inputs.v1",
                        "status": "prepared-not-release-qualified",
                        "sdkArchiveSHA256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                        "sdkArchiveSizeBytes": archive.stat().st_size, "sourceProjects": [project]}
        (root / "build-inputs").mkdir()
        (root / "build-inputs/build-inputs.json").write_text(json.dumps(build_inputs))
        return root

    def test_accepts_evidence_only_changes_to_old_complete_sdk(self):
        result = REUSE.compare(self.repo, self.producer, self.consumer)
        self.assertEqual(result["status"], "compatible-not-release-qualified")
        self.assertEqual(result["producer"], {"commit": self.producer})
        self.assertEqual(result["sourceCommit"], self.consumer)

    def test_rejects_changed_compiler_inputs(self):
        self._write_recipe(changed_compile=True)
        changed = self.commit("compiler input changed")
        with self.assertRaisesRegex(ValueError, "compile inputs differ"):
            REUSE.compare(self.repo, self.producer, changed)

    def test_rejects_source_sha_that_is_not_current_head(self):
        with self.assertRaisesRegex(ValueError, "current checkout"):
            REUSE.compare(self.repo, self.producer, self.producer)

    def test_rejects_non_ancestor_producer(self):
        self.git("checkout", "-q", "--detach", self.producer)
        self._write_recipe(evidence_only=True)
        sibling = self.commit("sibling compilation source")
        self.git("checkout", "-q", "--detach", self.consumer)
        with self.assertRaisesRegex(ValueError, "not an ancestor"):
            REUSE.compare(self.repo, sibling, self.consumer)

    def test_compares_source_inventories_with_current_pins(self):
        result = REUSE.compare(self.repo, self.producer, self.consumer, self.records())
        self.assertEqual(result["sourceInventory"]["projectCount"], 1)
        with self.assertRaisesRegex(ValueError, "source revision differs"):
            REUSE.compare(self.repo, self.producer, self.consumer, self.records(wrong_pin=True))

    def test_rejects_incomplete_or_duplicate_source_inventories(self):
        records = self.records()
        for filename, key in (("source-revisions.json", "projects"),
                              ("build-inputs/build-inputs.json", "sourceProjects")):
            path = records / filename
            original = path.read_bytes()
            inventory = json.loads(original)
            for rows in ([], inventory[key] * 2):
                with self.subTest(filename=filename, count=len(rows)):
                    path.write_text(json.dumps({**inventory, key: rows}))
                    with self.assertRaisesRegex(ValueError, "source inventory differs"):
                        REUSE.compare(self.repo, self.producer, self.consumer, records)
            path.write_bytes(original)

    def test_rejects_changed_or_missing_sdk_archive(self):
        records = self.records()
        archive = records / "swift-static-sdk.tar.gz"
        archive.write_bytes(b"different SDK payload")
        with self.assertRaisesRegex(ValueError, "archive differs"):
            REUSE.compare(self.repo, self.producer, self.consumer, records)
        archive.unlink()
        with self.assertRaisesRegex(ValueError, "archive is missing"):
            REUSE.compare(self.repo, self.producer, self.consumer, records)

    def test_rejects_unrecognized_compiler_step(self):
        self._write_recipe(evidence_only=True)
        workflow = (self.repo / ".github/workflows/runtime-ingredients.yml").read_text()
        workflow = workflow.replace("      - name: Materialize the exact Swift source revisions\n",
                                    "      - name: New compiler setup step\n        run: install-more-tools\n"
                                    "      - name: Materialize the exact Swift source revisions\n")
        (self.repo / ".github/workflows/runtime-ingredients.yml").write_text(workflow)
        changed = self.commit("unreviewed SDK setup step")
        with self.assertRaisesRegex(ValueError, "compiler setup steps changed"):
            REUSE.compare(self.repo, self.producer, changed)

    def test_rejects_modified_optional_step(self):
        self._write_recipe(evidence_only=True)
        path = self.repo / ".github/workflows/runtime-ingredients.yml"
        path.write_text(path.read_text().replace(
            'run: test -z "$REQUESTED_CHECKPOINT_ATTEMPT"',
            'run: echo "compile-side-effect"'))
        changed = self.commit("modified optional workflow step")
        with self.assertRaisesRegex(ValueError, "optional SDK workflow step contents changed"):
            REUSE.compare(self.repo, self.producer, changed)

    def test_rejects_duplicate_optional_step(self):
        self._write_recipe(evidence_only=True)
        path = self.repo / ".github/workflows/runtime-ingredients.yml"
        text = path.read_text()
        block = REUSE.OPTIONAL_PRE_BUILD_STEPS["Validate checkpoint input pairing"]
        path.write_text(text.replace(block, block + block))
        changed = self.commit("duplicated optional workflow step")
        with self.assertRaisesRegex(ValueError, "optional SDK workflow step is duplicated"):
            REUSE.compare(self.repo, self.producer, changed)

    def test_rejects_changed_global_environment(self):
        self._write_recipe(evidence_only=True, global_env="env:\n  CC: clang\n")
        changed = self.commit("global compiler environment added")
        with self.assertRaisesRegex(ValueError, "compile inputs differ"):
            REUSE.compare(self.repo, self.producer, changed)

    def test_rejects_changed_global_defaults(self):
        self._write_recipe(evidence_only=True, global_env="defaults:\n  run:\n    shell: bash\n")
        changed = self.commit("global workflow defaults added")
        with self.assertRaisesRegex(ValueError, "compile inputs differ"):
            REUSE.compare(self.repo, self.producer, changed)

    def test_rejects_duplicate_job_environment(self):
        self._write_recipe(evidence_only=True)
        path = self.repo / ".github/workflows/runtime-ingredients.yml"
        text = path.read_text().replace(
            "    steps:\n", "    env:\n      CC: clang\n    env:\n      CXX: clang++\n    steps:\n")
        path.write_text(text)
        changed = self.commit("duplicate compiler environment")
        with self.assertRaisesRegex(ValueError, "duplicate SDK build job setting: env"):
            REUSE.compare(self.repo, self.producer, changed)

    def test_rejects_multiline_runner(self):
        self._write_recipe(evidence_only=True)
        path = self.repo / ".github/workflows/runtime-ingredients.yml"
        path.write_text(path.read_text().replace(
            "    runs-on: ubuntu-24.04-arm\n",
            "    runs-on:\n      - ubuntu-24.04-arm\n"))
        changed = self.commit("multiline runner configuration")
        with self.assertRaisesRegex(ValueError, "runner configuration is unsupported"):
            REUSE.compare(self.repo, self.producer, changed)

    def test_allows_dispatch_input_changes(self):
        self._write_recipe(evidence_only=True)
        path = self.repo / ".github/workflows/runtime-ingredients.yml"
        path.write_text(path.read_text().replace(
            "  workflow_dispatch:\n", "  workflow_dispatch:\n    inputs:\n      extra:\n        type: string\n"))
        changed = self.commit("dispatch input only")
        self.assertEqual(REUSE.compare(self.repo, self.producer, changed)["status"],
                         "compatible-not-release-qualified")


if __name__ == "__main__":
    unittest.main()
