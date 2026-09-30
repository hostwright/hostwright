#!/usr/bin/env python3
"""Focused tests for the retained SDK mapping recovery boundary."""

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("recover-sdk-object-sources.py")
SPEC = importlib.util.spec_from_file_location("sdk_source_recovery", SCRIPT)
RECOVERY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RECOVERY)


def digest(data):
    return hashlib.sha256(data).hexdigest()


class SDKObjectSourceRecoveryTests(unittest.TestCase):
    def fixture(self, root):
        records = root / "records"
        (records / "build-inputs").mkdir(parents=True)
        files = {
            "build-inputs/sdk-object-sources.json": b'{"archiveMembers":[],"counts":{"archiveMembers":0,"mappedMembers":0,"unresolvedMembers":0,"mappedObjects":0},"emptyNonSourceMembers":[],"kind":"hostwright.sdk-object-sources.v1","mappingEvidence":[],"rejectedInputs":[],"sourceMap":[],"status":"partial-not-release-qualified","unresolved":[]}\n',
            "build-inputs/build-inputs.json": b'{"sourceProjects":[]}\n',
            "build-inputs/objects.json": b'[]\n',
            "build.trace": b"retained trace fixture\n",
            "swift-static-sdk.tar.gz": b"retained SDK fixture\n",
        }
        for name, data in files.items():
            destination = records / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
        checksum_rows = "".join(f"{digest(data)}  ./{name}\n" for name, data in files.items())
        (records / "checksums.sha256").write_text(checksum_rows)
        return records, files

    def test_no_missing_bzip_gap_copies_original_map_byte_for_byte(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            records, files = self.fixture(root)
            output = records / "build-inputs/sdk-object-sources.recovered.json"
            result = RECOVERY.recover(records, output, root / "work")
            self.assertEqual(result["recovered"], 0)
            self.assertTrue((Path(result["evidence"]) / "recovery.json").is_file())
            self.assertEqual(output.read_bytes(), files["build-inputs/sdk-object-sources.json"])
            self.assertEqual((records / "checksums.sha256").read_text(),
                             "".join(f"{digest(data)}  ./{name}\n" for name, data in files.items()))

    def test_tampered_object_inventory_is_rejected_before_recovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            records, _ = self.fixture(root)
            (records / "build-inputs/objects.json").write_bytes(b'[{"sha256":"tampered"}]\n')
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                RECOVERY.recover(records, records / "build-inputs/recovered.json", root / "work")
            self.assertFalse((records / "build-inputs/recovered.json").exists())

    def test_missing_trace_checksum_or_trace_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            records, _ = self.fixture(root)
            (records / "build.trace").unlink()
            with self.assertRaisesRegex(ValueError, "missing checksummed SDK evidence: build.trace"):
                RECOVERY.recover(records, records / "build-inputs/recovered.json", root / "work")
            self.assertFalse((records / "build-inputs/recovered.json").exists())


if __name__ == "__main__":
    unittest.main()
