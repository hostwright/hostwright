#!/usr/bin/env python3
import importlib.util
import copy
import ast
import hashlib
import json
from pathlib import Path
import re
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

    def patched_guest_fixture(self):
        old_revision, new_revision = "a" * 40, "b" * 40
        def resolved(revision):
            return Q.V.canonical(dict(pins=[dict(identity="guest-dependency",
                location="https://github.com/example/guest-dependency", state=dict(revision=revision, version="2.0.0"))]))
        before, after = resolved(old_revision), resolved(new_revision)
        contents = {"LICENSE": b"Fixture license text\n", "NOTICE": b"Fixture notice text\n",
                    "vminitd/Package.resolved": before}
        records = {}
        def add(name, data):
            records[name] = data
            return dict(path=name, sha256=Q.sha(data), sizeBytes=len(data))
        leaves = [dict(path=name, gitMode="100644", gitBlobSHA1=Q.V.git_object("blob", data),
                       sha256=Q.sha(data), sizeBytes=len(data)) for name, data in sorted(contents.items())]
        child = Q.V.git_object("tree", b"100644 Package.resolved\0" +
                              bytes.fromhex(Q.V.git_object("blob", before)))
        tree = Q.V.git_object("tree", b"".join(
            b"100644 " + name.encode() + b"\0" + bytes.fromhex(Q.V.git_object("blob", contents[name]))
            for name in ["LICENSE", "NOTICE"]) + b"40000 vminitd\0" + bytes.fromhex(child))
        commit = b"tree " + tree.encode() + b"\nauthor Fixture <fixture@example.invalid> 1 +0000\n\nFixture\n"
        def license_record(name):
            return dict(add("proof/" + name, contents[name]), sourcePath=name, component="containerization", spdx="MIT")
        patch = (b"--- a/vminitd/Package.resolved\n+++ b/vminitd/Package.resolved\n@@ -1 +1 @@\n-" + before + b"+" + after)
        effective = dict(contents, **{"vminitd/Package.resolved": after})
        framework = dict(identity="containerization", commit=Q.V.git_object("commit", commit), tree=tree,
            spdx="MIT", commitObject=add("proof/source.commit", commit), archive=add("proof/source.tar.gz", F.tar(contents)),
            inventory=add("proof/inventory.json", Q.V.canonical(leaves)), licenses=[license_record("LICENSE")],
            notices=[license_record("NOTICE")], patches=[dict(add("proof/guest.patch", patch),
                beforeInventorySHA256=Q.sha(Q.V.canonical({p:Q.sha(d) for p,d in contents.items()})),
                afterInventorySHA256=Q.sha(Q.V.canonical({p:Q.sha(d) for p,d in effective.items()})))])
        return framework, dict(containerization=framework, **{"guest-dependency": dict(commit=new_revision)}), records, after

    def test_guest_inventory_uses_authenticated_patched_resolved_pins(self):
        framework, projects, records, after = self.patched_guest_fixture()
        resolved, dependencies = Q.effective_guest_dependencies(framework, projects, records.__getitem__)
        self.assertEqual(resolved, after)
        self.assertEqual(dependencies[0]["revision"], "b" * 40)
        baseline = next(item for item in Q.V.parse(records[framework["inventory"]["path"]])
                        if item["path"] == "vminitd/Package.resolved")
        self.assertNotEqual(Q.sha(resolved), baseline["sha256"])

    def test_effective_guest_pin_requires_matching_captured_source(self):
        framework, projects, records, _ = self.patched_guest_fixture()
        for replacement in ({}, {"guest-dependency": dict(commit="c" * 40)}):
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                Q.effective_guest_dependencies(framework, dict(containerization=framework, **replacement), records.__getitem__)

    def test_resolved_only_guest_pin_requires_the_entire_retained_tuple(self):
        framework, projects, records, _ = self.patched_guest_fixture()
        _, dependencies = Q.effective_guest_dependencies(framework, projects, records.__getitem__)
        projects.pop("guest-dependency")
        _, retained = Q.effective_guest_dependencies(framework, projects, records.__getitem__, dependencies)
        self.assertEqual(retained, dependencies)
        for field in ["revision", "location", "version"]:
            changed = [dict(dependencies[0], **{field: "different"})]
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "exact retained baseline"):
                Q.effective_guest_dependencies(framework, projects, records.__getitem__, changed)

    def test_resolved_only_guest_pin_cannot_create_a_license_receipt(self):
        dependencies = [dict(identity="guest-dependency", revision="b" * 40)]
        with self.assertRaisesRegex(ValueError, "exact license receipt"):
            Q.refresh_guest_documents(bytearray(), [], dependencies, {}, lambda _: b"unused", "d" * 64)

    def test_guest_inventory_refuses_tampered_patch_or_inventory(self):
        framework, projects, records, _ = self.patched_guest_fixture()
        for field in ["beforeInventorySHA256", "afterInventorySHA256", "sha256"]:
            changed = copy.deepcopy(framework);changed["patches"][0][field] = "0" * 64
            with self.subTest(field=field), self.assertRaises(ValueError):
                Q.effective_guest_dependencies(changed, dict(projects, containerization=changed), records.__getitem__)

    def test_guest_license_refresh_preserves_baseline_and_is_idempotent(self):
        notices = bytearray(b"Host license notices\n");records = []
        Q.add_document(notices, records, "runtime-guest-license", "guest-swift/guest-dependency@" + "a" * 40 + "/LICENSE",
                       b"Historical guest license\n", ["historical-source"])
        original = bytes(notices)
        license_data = b"Actual patched guest license\n"
        project = dict(identity="guest-dependency", commit="b" * 40,
                       archive=dict(path="source/guest.tar.gz", sha256="c" * 64, sizeBytes=123),
                       licenses=[dict(path="proof/LICENSE", sourcePath="LICENSE", sha256=Q.sha(license_data), sizeBytes=len(license_data))])
        dependencies = [dict(identity="guest-dependency", revision="b" * 40)]
        for _ in range(2):
            Q.refresh_guest_documents(notices, records, dependencies, {"guest-dependency": project},
                                      {"proof/LICENSE": license_data}.__getitem__, "d" * 64)
        self.assertTrue(bytes(notices).startswith(original))
        self.assertEqual(records[0]["category"], "runtime-upstream-guest-license")
        self.assertEqual(len(records), 2)
        self.assertEqual(records[1]["sourcePath"], "guest-swift/guest-dependency@" + "b" * 40 + "/LICENSE")
        Q.bind_notice_digests(notices, dict(dependencies=[], runtimeDocuments=records), {})
        Q.add_document(notices, records, "runtime-native-license", "runtime-source/guest/LICENSE", license_data, ["source"])
        cleaned, retained = Q.remove_generated_runtime_documents(notices, records)
        before = bytes(cleaned)
        Q.refresh_guest_documents(cleaned, retained, dependencies, {"guest-dependency": project},
                                  {"proof/LICENSE": license_data}.__getitem__, "d" * 64)
        self.assertEqual(bytes(cleaned), before)

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

    def test_kernel_references_bind_current_source_and_recipe_without_checkout_commit(self):
        kernel_commit = "725bd2f3c81d54edccb66fead01d4c0c222e2231"
        recipe_revision = Q.V.git_object("blob", b"exact reviewed recipe\n")
        refs = Q.kernel_source_references(kernel_commit, recipe_revision)
        self.assertEqual(refs[0], "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.55.tar.xz")
        self.assertTrue(refs[1].endswith("?id=" + kernel_commit))
        self.assertEqual(refs[2], "git-blob:hostwright:" + recipe_revision + ":" + Q.KERNEL_RECIPE_PATH)
        self.assertNotIn("6.18.15", "\n".join(refs))
        self.assertNotIn("kata-containers", "\n".join(refs))
        for kernel, recipe in [("bad", recipe_revision), (kernel_commit, "bad")]:
            with self.assertRaisesRegex(ValueError, "invalid kernel source or recipe revision"):
                Q.kernel_source_references(kernel, recipe)

    def test_qualified_loader_build_settings_require_authenticated_target(self):
        def loader(lines):
            def string(data):
                return bytes([len(data)]) + data
            header = bytearray(32)
            header[:14] = b"\xff Go buildinf:"
            header[14] = 8
            header[15] = 2
            return b"\0" * 16 + bytes(header) + string(b"go1.26.5") + string(b"\0" * 16 + lines + b"\0" * 16)

        valid = loader(b"build\tGOOS=linux\nbuild\tGOARCH=arm64\nbuild\tCGO_ENABLED=0\n")
        self.assertEqual(Q.qualified_loader_build_settings(valid),
                         {"GOOS": "linux", "GOARCH": "arm64", "CGO_ENABLED": "0"})
        for lines in (
            b"build\tGOOS=linux\nbuild\tGOARCH=arm64\n",
            b"build\tGOOS=linux\nbuild\tGOARCH=amd64\nbuild\tCGO_ENABLED=0\n",
        ):
            with self.assertRaisesRegex(ValueError, "authenticated target environment"):
                Q.qualified_loader_build_settings(loader(lines))

    def test_kernel_linker_uses_configuration_and_bound_tool_version_not_swift_identity(self):
        records = {}

        def tool(identity, path, version):
            data = version.encode()
            records[identity] = data
            return dict(identity=identity, executablePath=path, executable=dict(sha256=identity),
                        version=dict(path=identity, sha256=Q.sha(data), sizeBytes=len(data)))

        compiler = tool("kernel-compiler", "/usr/bin/gcc", "gcc 13.3.0")
        bfd = tool("native-ld", "/usr/bin/ld", "GNU ld (GNU Binutils for Ubuntu) 2.42\nCopyright GNU\n")
        lld = tool("linker", "/swift/usr/bin/ld.lld", "LLD 21.0.0 (compatible with GNU linkers)")
        manifest = dict(kernel=dict(compiler=compiler["executable"]), toolchain=[compiler, lld, bfd])
        config = b"CONFIG_LD_IS_BFD=y\nCONFIG_LD_VERSION=24200\nCONFIG_LLD_VERSION=0\n"
        self.assertEqual(Q.kernel_tool_versions(manifest, config, records.__getitem__),
                         dict(compiler="gcc 13.3.0", linker=records["native-ld"].decode().strip()))
        llvm_config = b"CONFIG_LD_IS_LLD=y\nCONFIG_LD_VERSION=0\nCONFIG_LLD_VERSION=210000\n"
        self.assertEqual(Q.kernel_tool_versions(manifest, llvm_config, records.__getitem__)["linker"],
                         records["linker"].decode())
        for invalid in (b"", config.replace(b"24200", b"24300"), config + b"CONFIG_LD_IS_LLD=y\n",
                        config + b"CONFIG_LD_VERSION=24200\n"):
            with self.subTest(config=invalid), self.assertRaises(ValueError):
                Q.kernel_tool_versions(manifest, invalid, records.__getitem__)
        for tools in ([compiler, lld], [compiler, lld, bfd, dict(bfd, executablePath="/other/ld")],
                      [lld, bfd], [compiler, dict(compiler), lld, bfd]):
            with self.subTest(tools=tools), self.assertRaises(ValueError):
                Q.kernel_tool_versions(dict(manifest, toolchain=tools), config, records.__getitem__)
        records["native-ld"] += b"tampered"
        with self.assertRaisesRegex(ValueError, "evidence bytes mismatch"):
            Q.kernel_tool_versions(manifest, config, records.__getitem__)

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

    def test_kernel_configuration_migration_preserves_other_notices_and_is_idempotent(self):
        original = bytearray(b"host notices\n")
        records = []
        Q.add_document(original, records, "runtime-kernel-config", Q.PREVIOUS_CONFIG_DOC_PATH,
                       b"CONFIG_ARM64=y\n", ["old-configuration"])
        Q.add_document(original, records, "runtime-license", "other/LICENSE", b"preserved license\n", ["other"])
        before = bytes(original)
        updated_config = b"CONFIG_ARM64=y\nCONFIG_IPV6=y\n"
        result = Q.replace_kernel_configuration(original, records, updated_config, "a" * 64)
        self.assertEqual(bytes(original), before)
        self.assertNotIn(Q.PREVIOUS_CONFIG_DOC_PATH.encode(), result)
        self.assertIn(Q.CONFIG_DOC_PATH.encode(), result)
        self.assertEqual(records[0]["sourcePath"], Q.CONFIG_DOC_PATH)
        for record in records:
            data = result[record["offsetBytes"]:record["offsetBytes"] + record["sizeBytes"]]
            self.assertEqual(Q.sha(data), record["sha256"])
        other = records[1]
        self.assertEqual(result[other["offsetBytes"]:other["offsetBytes"] + other["sizeBytes"]],
                         b"preserved license\n")
        self.assertEqual(Q.replace_kernel_configuration(result, records, updated_config, "a" * 64), result)

    def test_kernel_configuration_migration_rejects_ambiguous_or_corrupt_records(self):
        for corruption in ("header", "contents", "duplicate"):
            notices = bytearray(b"host notices\n")
            records = []
            Q.add_document(notices, records, "runtime-kernel-config", Q.PREVIOUS_CONFIG_DOC_PATH,
                           b"CONFIG_ARM64=y\n", ["old-configuration"])
            if corruption == "duplicate":
                Q.add_document(notices, records, "runtime-kernel-config", Q.CONFIG_DOC_PATH,
                               b"CONFIG_ARM64=y\n", ["current-configuration"])
            else:
                offset = records[0]["offsetBytes"] - 3 if corruption == "header" else records[0]["offsetBytes"]
                notices[offset] ^= 1
            with self.subTest(corruption=corruption), self.assertRaises(ValueError):
                Q.replace_kernel_configuration(notices, records, b"CONFIG_ARM64=y\n", "a" * 64)

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
            "ThirdPartyLicenses/runtime-build-recipes/kernel-actual-config-6.18.55-186": b"CONFIG_ARM64=y\n",
        }
        committed = Q.V.parse(generated["runtime-license-inventory.json"])
        committed["retainedLoaderSourceRevision"] = historical
        (source / "runtime-license-inventory.json").write_bytes(Q.V.canonical(committed))
        for relative in (
            "THIRD_PARTY_NOTICES",
            "third-party-license-inventory.json",
            "ThirdPartyLicenses/runtime-build-recipes/source-documents.json",
            "ThirdPartyLicenses/runtime-build-recipes/kernel-actual-config-6.18.55-186",
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


class CommittedRuntimePinTests(unittest.TestCase):
    def setUp(self):
        self.root = HERE.parent.parent
        self.inventory = json.loads((self.root / "runtime-license-inventory.json").read_text())
        swift = (self.root / "Sources/HostwrightCore/ContainerizationRuntimeAssetContract.swift").read_text()
        self.swift = {name: ast.literal_eval(value) for name, value in re.findall(
            r'public static let (\w+)(?:: Int64)?\s*=\s*("[^"\\\n]*"|[\d_]+)', swift)}
        shell = (HERE / "prepare-containerization-assets.sh").read_text()
        self.shell = dict(re.findall(r'^readonly (\w+)="([^"]*)"$', shell, re.M))
        harness = ast.parse((self.root / "scripts/qualification/authenticated-lifecycle.py").read_text())
        self.harness = {node.targets[0].id: ast.literal_eval(node.value) for node in harness.body
                        if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
                        and node.targets[0].id.startswith("SDK_")}

    def test_inventory_payloads_match_compiled_and_preparation_pins(self):
        expected = {}
        for swift_digest, swift_size, shell_digest, shell_size, relative in [
            ("kernelSHA256", "kernelSize", "kernel_sha256", "kernel_size", "kernel/" + self.swift["kernelFileName"]),
            ("guestNetworkPolicyLoaderSHA256", "guestNetworkPolicyLoaderSize", "guest_loader_sha256", "guest_loader_size", "guest/hostwright-netfilter"),
            ("initImageIndexJSONSHA256", "initImageIndexJSONSize", "index_sha256", "index_size", "vminit/index.json"),
            ("initImageLayoutSHA256", "initImageLayoutSize", "layout_sha256", "layout_size", "vminit/oci-layout"),
            *[("initImage" + name + "Digest", "initImage" + name + "Size", shell + "_digest", shell + "_size",
               "vminit/blobs/sha256/" + self.swift["initImage" + name + "Digest"])
              for name, shell in [("Manifest", "manifest"), ("Configuration", "configuration"), ("Layer", "layer")]],
        ]:
            with self.subTest(payload=relative):
                digest, size = self.swift[swift_digest], self.swift[swift_size]
                self.assertEqual((self.shell[shell_digest], int(self.shell[shell_size])), (digest, size))
                expected["share/hostwright/containerization/" + relative] = (digest, size)
        self.assertEqual({item["path"]: (item["sha256"], item["sizeBytes"])
                          for item in self.inventory["payloadFiles"]}, expected)
        self.assertEqual(self.inventory["initImageReference"], "untagged@sha256:" + self.swift["initImageManifestDigest"])
        for field, pin in [("initImageConfigurationSHA256", "initImageConfigurationDigest"),
                           ("initImageLayerSHA256", "initImageLayerDigest")]:
            self.assertEqual(self.inventory[field], self.swift[pin])

    def test_lifecycle_requires_the_same_kernel_and_oci_payloads(self):
        self.assertEqual(self.harness["SDK_KERNEL_SHA256"], self.swift["kernelSHA256"])
        self.assertEqual(self.harness["SDK_KERNEL_SIZE"], self.swift["kernelSize"])
        prefix = "share/hostwright/containerization/vminit/"
        expected = {item["path"][len(prefix):]: (item["sha256"], item["sizeBytes"])
                    for item in self.inventory["payloadFiles"] if item["path"].startswith(prefix)}
        self.assertEqual(self.harness["SDK_INIT_ASSETS"], expected)
        self.assertEqual(self.harness["SDK_INIT_VARIANT_DIGEST"], "sha256:" + self.swift["initImageManifestDigest"])

    def test_kernel_notice_attribution_matches_verified_payload(self):
        expected = "embedded-IKCFG_ST:sha256:" + self.swift["kernelSHA256"]
        third_party = json.loads((self.root / Q.THIRD_PARTY_INVENTORY).read_bytes())
        records = [row for row in third_party["runtimeDocuments"]
                   if row["sourcePath"] == Q.CONFIG_DOC_PATH]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["sourcePaths"], [expected])
        config = (self.root / Q.CONFIG_PATH).read_bytes()
        self.assertEqual((records[0]["sha256"], records[0]["sizeBytes"]),
                         (hashlib.sha256(config).hexdigest(), len(config)))
        documents = json.loads((self.root / Q.SOURCE_DOCUMENTS).read_bytes())
        source_configs = [row for row in documents if row["path"] == Q.SOURCE_CONFIG_PATH]
        self.assertEqual(len(source_configs), 1)
        self.assertEqual(source_configs[0]["url"], expected)

    def test_imported_index_is_derived_from_current_manifest(self):
        manifest = dict(digest="sha256:" + self.swift["initImageManifestDigest"],
                        mediaType="application/vnd.oci.image.manifest.v1+json", size=self.swift["initImageManifestSize"])
        direct = dict(manifests=[manifest], mediaType="application/vnd.oci.image.index.v1+json", schemaVersion=2)
        direct_bytes = json.dumps(direct, sort_keys=True, separators=(",", ":")).encode()
        self.assertEqual((hashlib.sha256(direct_bytes).hexdigest(), len(direct_bytes)),
                         (self.swift["initImageIndexJSONSHA256"], self.swift["initImageIndexJSONSize"]))
        manifest["platform"] = dict(architecture="arm64", os="linux")
        direct["annotations"] = {"com.apple.containerization.index.indirect": "true"}
        imported_bytes = json.dumps(direct, sort_keys=True, separators=(",", ":")).replace("/", "\\/").encode()
        digest = hashlib.sha256(imported_bytes).hexdigest()
        self.assertEqual((digest, len(imported_bytes)),
                         (self.swift["initImageImportedIndexSHA256"], self.swift["initImageImportedIndexSize"]))
        self.assertEqual(self.harness["SDK_INIT_DESCRIPTOR_DIGEST"], "sha256:" + digest)
        self.assertEqual(self.harness["SDK_INIT_IMPORTED_INDEX_SIZE"], len(imported_bytes))


if __name__ == "__main__":
    unittest.main()
