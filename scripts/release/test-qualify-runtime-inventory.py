#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import tempfile
import unittest


HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


Q = load("runtime_inventory_qualifier", "qualify-runtime-inventory.py")
F = load("runtime_provenance_fixture", "test-runtime-provenance.py")


class RuntimeInventoryQualificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.prepared = self.root / "prepared"
        self.prepared.mkdir()
        self.manifest, self.runtime, self.payloads, self.evidence = F.fixture()
        self.write("runtime-provenance/manifest.json", Q.V.canonical(self.manifest))
        self.write("licenses/runtime-license-inventory.json", Q.V.canonical(self.runtime))
        for name, data in self.evidence.items():
            self.write(name, data)
        for name, data in self.payloads.items():
            self.write("runtime-provenance/payloads/" + name, data)

    def write(self, name, data):
        target = self.prepared / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        return target

    def test_full_verifier_accepts_prepared_fixture_without_auth_claim(self):
        manifest, runtime, _, _, _, result = Q.verify_prepared_evidence(self.prepared)
        self.assertEqual(manifest["sourceCommit"], result["sourceCommit"])
        self.assertEqual(len(runtime["assets"]), 3)

    def test_tampered_payload_fails_full_verification(self):
        path = self.manifest["payloads"][0]["path"]
        target = self.prepared / "runtime-provenance/payloads" / path
        target.write_bytes(target.read_bytes() + b"tampered")
        with self.assertRaisesRegex(ValueError, "evidence bytes mismatch"):
            Q.verify_prepared_evidence(self.prepared)

    def test_tampered_source_archive_fails_full_verification(self):
        target = self.prepared / "proof/source.tar.gz"
        target.write_bytes(target.read_bytes() + b"tampered")
        with self.assertRaisesRegex(ValueError, "evidence bytes mismatch"):
            Q.verify_prepared_evidence(self.prepared)

    def test_notice_digest_and_document_offsets_cover_all_bytes(self):
        notices = bytearray(b"existing host notices\n")
        third_party = dict(dependencies=[dict(documents=[])], runtimeDocuments=[])
        runtime = {}
        Q.add_document(notices, third_party["runtimeDocuments"], "runtime-native-license",
                       "runtime-source/example/LICENSE", b"Example license text\n",
                       ["git-object:example@" + "a" * 40 + ":LICENSE"])
        digest = Q.bind_notice_digests(notices, third_party, runtime)
        self.assertEqual(digest, Q.sha(bytes(notices)))
        self.assertEqual(runtime["noticesSHA256"], third_party["noticesSHA256"])
        record = third_party["runtimeDocuments"][0]
        self.assertEqual(bytes(notices[record["offsetBytes"]:record["offsetBytes"] + record["sizeBytes"]]),
                         b"Example license text\n")
        notices[record["offsetBytes"]] ^= 1
        with self.assertRaisesRegex(ValueError, "notice document offset or digest mismatch"):
            Q.bind_notice_digests(notices, third_party, runtime)

    def test_payload_records_cover_verified_digests_and_modes(self):
        loader = self.manifest["loader"]["path"]
        records = Q.payload_file_records(self.manifest, self.payloads, loader)
        self.assertEqual(len(records), 7)
        self.assertEqual({record["path"] for record in records}, set(self.payloads))
        self.assertEqual({record["mode"] for record in records if record["path"] == loader}, {0o755})
        self.assertEqual({record["mode"] for record in records if record["path"] != loader}, {0o644})
        changed = dict(self.payloads)
        changed[loader] += b"tampered"
        with self.assertRaisesRegex(ValueError, "payload bytes differ"):
            Q.payload_file_records(self.manifest, changed, loader)


if __name__ == "__main__":
    unittest.main()
