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

    def test_loader_source_closure_digest_binds_exact_twenty_files_and_license(self):
        files = {"LICENSE": b"Hostwright license\n"}
        files.update({"Guest/HostwrightNetfilter/source-%02d.go" % index:
                      ("source %02d\n" % index).encode() for index in range(20)})
        digest = Q.loader_source_closure_digest(files)
        self.assertEqual(digest, Q.loader_source_closure_digest(dict(reversed(list(files.items())))))
        changed = dict(files)
        changed["Guest/HostwrightNetfilter/source-00.go"] += b"changed"
        self.assertNotEqual(digest, Q.loader_source_closure_digest(changed))
        del changed["LICENSE"]
        with self.assertRaisesRegex(ValueError, "retained 20 files and LICENSE"):
            Q.loader_source_closure_digest(changed)

    def test_source_references_are_content_addressed_and_run_independent(self):
        hostwright = dict(identity="hostwright", archive=dict(
            path="runtime-provenance/source-projects/hostwright.tar.gz",
            sha256="a" * 64, sizeBytes=120))
        pinned = dict(identity="kernel", archive=dict(
            path="runtime-provenance/source-projects/kernel.tar.gz",
            sha256="b" * 64, sizeBytes=300))
        host_ref = Q.stable_source_reference(hostwright, "c" * 64)
        pinned_ref = Q.stable_source_reference(pinned, "c" * 64)
        self.assertEqual(host_ref, "prepared-local-source-coverage:hostwright-loader-source+LICENSE#sha256=" + "c" * 64)
        self.assertIn("kernel.tar.gz#sha256=" + "b" * 64 + "&sizeBytes=300", pinned_ref)
        self.assertNotIn("manifest.json", host_ref + pinned_ref)

    def test_regeneration_replaces_prior_runtime_notice_sections_idempotently(self):
        base = bytearray(b"host notices\n")
        records = []
        Q.add_document(base, records, "runtime-kernel-config", Q.CONFIG_DOC_PATH,
                       b"CONFIG_ARM64=y\n", ["embedded-IKCFG_ST:sha256:" + "a" * 64])
        preserved = [dict(records[0])]
        Q.add_document(base, records, "runtime-loader-license", "runtime-source/hostwright/LICENSE",
                       b"Hostwright license\n", ["hostwright-source#sha256=" + "b" * 64])
        Q.add_document(base, records, "runtime-native-license", "runtime-source/lib/LICENSE",
                       b"Library license\n", ["source-archive#sha256=" + "c" * 64])
        qualified_notices = bytearray(base)
        cleaned, retained = Q.remove_generated_runtime_documents(qualified_notices, records)
        self.assertEqual(cleaned, bytes(base[:records[0]["offsetBytes"] + records[0]["sizeBytes"]]))
        self.assertEqual(retained, preserved)

        rebuilt = bytearray(cleaned)
        rebuilt_records = [dict(retained[0])]
        Q.add_document(rebuilt, rebuilt_records, "runtime-loader-license", "runtime-source/hostwright/LICENSE",
                       b"Hostwright license\n", ["hostwright-source#sha256=" + "b" * 64])
        Q.add_document(rebuilt, rebuilt_records, "runtime-native-license", "runtime-source/lib/LICENSE",
                       b"Library license\n", ["source-archive#sha256=" + "c" * 64])
        self.assertEqual(rebuilt, qualified_notices)
        self.assertEqual(rebuilt_records, records)
        second_clean, second_retained = Q.remove_generated_runtime_documents(rebuilt, rebuilt_records)
        self.assertEqual(second_clean, cleaned)
        self.assertEqual(second_retained, retained)

        tampered = bytearray(rebuilt)
        tampered[records[-1]["offsetBytes"]] ^= 1
        with self.assertRaisesRegex(ValueError, "differs from its indexed bytes"):
            Q.remove_generated_runtime_documents(tampered, rebuilt_records)

    def test_committed_inventory_and_public_outputs_must_match_fresh_proof(self):
        source = self.root / "source"
        source.mkdir()
        historical = "1" * 40
        generated = {
            "runtime-license-inventory.json": Q.V.canonical(dict(
                status="qualified", retainedLoaderSourceRevision="2" * 40,
                assets=[dict(identity="kernel", sha256="a" * 64, sizeBytes=10)])),
            "THIRD_PARTY_NOTICES": b"qualified notices\n",
            "third-party-license-inventory.json": b"qualified dependency inventory\n",
            "ThirdPartyLicenses/runtime-build-recipes/source-documents.json": b"qualified source docs\n",
            "ThirdPartyLicenses/runtime-build-recipes/kernel-actual-config-6.18.15-186": b"CONFIG_ARM64=y\n",
        }
        committed = Q.V.parse(generated["runtime-license-inventory.json"])
        committed["retainedLoaderSourceRevision"] = historical
        (source / "runtime-license-inventory.json").write_bytes(Q.V.canonical(committed))
        for relative in (
            "THIRD_PARTY_NOTICES",
            "third-party-license-inventory.json",
            "ThirdPartyLicenses/runtime-build-recipes/source-documents.json",
            "ThirdPartyLicenses/runtime-build-recipes/kernel-actual-config-6.18.15-186",
        ):
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(generated[relative])
        self.assertEqual(Q.verify_committed_outputs(source, generated),
                         (source / "runtime-license-inventory.json").read_bytes())

        committed["assets"][0]["sha256"] = "d" * 64
        (source / "runtime-license-inventory.json").write_bytes(Q.V.canonical(committed))
        with self.assertRaisesRegex(ValueError, "differs from freshly verified"):
            Q.verify_committed_outputs(source, generated)
        committed["assets"][0]["sha256"] = "a" * 64
        (source / "runtime-license-inventory.json").write_bytes(Q.V.canonical(committed))
        (source / "THIRD_PARTY_NOTICES").write_bytes(b"modified notices\n")
        with self.assertRaisesRegex(ValueError, "notices/source documents differ"):
            Q.verify_committed_outputs(source, generated)


if __name__ == "__main__":
    unittest.main()
