#!/usr/bin/env python3
"""Exercise loader inventory updates against real clean Git source captures."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


Q = load("loader_inventory_qualifier", "qualify-runtime-inventory.py")
CAPTURE = load("loader_inventory_source_capture", "capture-runtime-source.py")


class LoaderInventoryUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "source"
        self.source.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Inventory tests")
        self.git("config", "user.email", "inventory@example.invalid")
        self.write("LICENSE", b"Fixture source license\n")
        self.write("Package.resolved", Q.V.canonical(dict(pins=[])))
        self.write(Q.NOTICES_FILE, b"Fixture source license\n")
        self.write(Q.CONFIG_PATH, b"CONFIG_FIXTURE=y\n")
        self.write(Q.SOURCE_DOCUMENTS, Q.V.canonical([]))
        self.old_sum = b"example.invalid/dependency v1.0.0 h1:" + b"A" * 43 + b"=\n"
        self.old_mod = b"module example.invalid/fixture\nrequire example.invalid/dependency v1.0.0\n"
        self.write("Guest/HostwrightNetfilter/go.mod", self.old_mod)
        self.write("Guest/HostwrightNetfilter/go.sum", self.old_sum)
        for i in range(18):
            self.write(f"Guest/HostwrightNetfilter/source{i}.go", b"package main\n")
        files = {str(p.relative_to(self.source)): Q.sha(p.read_bytes())
                 for p in (self.source / "Guest/HostwrightNetfilter").iterdir()}
        dependencies = [dict(module="example.invalid/dependency", version="v1.0.0", checksum="h1:" + "A" * 43 + "=")]
        self.runtime = dict(kind="hostwright.runtime-license-inventory.v1", schemaVersion=1,
                            status="qualified", noticesSHA256=Q.sha(b"Fixture source license\n"), guestDependencies=[],
                            retainedLoaderSourceFiles=files, retainedLoaderLinkedModules=dependencies * 6,
                            goDependencies=dependencies, goModuleSHA256=Q.sha(self.old_mod),
                            goSumSHA256=Q.sha(self.old_sum), assets=[dict(status="qualified", blockers=[], sourceDistributionEvidence=["fixture"])])
        self.write(Q.RUNTIME_INVENTORY, Q.V.canonical(self.runtime))
        third_party = dict(kind="hostwright.third-party-license-inventory.v1", schemaVersion=1,
                           resolvedSHA256=Q.sha((self.source / "Package.resolved").read_bytes()),
                           noticesSHA256=self.runtime["noticesSHA256"], dependencies=[], dependencyCount=0,
                           runtimeDocuments=[dict(offsetBytes=0, sizeBytes=23, sha256=self.runtime["noticesSHA256"])])
        self.write(Q.THIRD_PARTY_INVENTORY, Q.V.canonical(third_party))
        self.old_head = self.commit("qualified baseline")
        self.baseline = self.root / "baseline"
        self.git("worktree", "add", "-q", "--detach", str(self.baseline), self.old_head)
        self.new_sum = self.old_sum.replace(b"v1.0.0", b"v2.0.0")
        self.write("Guest/HostwrightNetfilter/go.sum", self.new_sum)
        self.write("Guest/HostwrightNetfilter/go.mod", self.old_mod.replace(b"v1.0.0", b"v2.0.0"))
        self.commit("dependency update")
        self.capture_number = 0

    def git(self, *args, root=None):
        return subprocess.check_output(["git", "-C", str(root or self.source), *args], text=True).strip()

    def write(self, name, data):
        path = self.source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def captured(self):
        self.capture_number += 1
        output = self.root / f"capture-{self.capture_number}"
        head = self.git("rev-parse", "HEAD")
        license_data = (self.source / "LICENSE").read_bytes()
        source = CAPTURE.capture(self.source, head, output)
        (output / "license.txt").write_bytes(license_data)
        license_record = dict(path="license.txt", sourcePath="LICENSE", component="hostwright",
                              spdx="Apache-2.0", sha256=Q.sha(license_data), sizeBytes=len(license_data))
        project = dict(source, identity="hostwright", spdx="Apache-2.0", patches=[],
                       licenses=[license_record], notices=[license_record])
        manifest = dict(sourceCommit=head, loader=dict(project="hostwright"), sourceProjects=[project])
        return manifest, lambda name: (output / name).read_bytes()

    def test_clean_ancestor_and_captured_update_refresh_only_loader_locks(self):
        self.assertEqual(Q.validate_loader_baseline(self.source, self.baseline), self.baseline)
        manifest, fetch = self.captured()
        before = copy.deepcopy(self.runtime)
        updated = Q.refresh_loader_locks(self.source, self.runtime, manifest, fetch)
        self.assertEqual(self.runtime, before)
        self.assertEqual(updated["goSumSHA256"], hashlib.sha256(self.new_sum).hexdigest())
        self.assertEqual(updated["goDependencies"][0]["version"], "v2.0.0")
        self.assertEqual(updated["retainedLoaderSourceFiles"]["Guest/HostwrightNetfilter/go.sum"], updated["goSumSHA256"])
        for field in set(before) - {"goModuleSHA256", "goSumSHA256", "retainedLoaderSourceFiles", "goDependencies"}:
            self.assertEqual(before[field], updated[field])

    def test_dirty_source_or_baseline_is_rejected(self):
        for root in (self.source, self.baseline):
            with self.subTest(root=root):
                (root / "unexpected").write_text("untracked\n")
                with self.assertRaisesRegex(ValueError, "must be clean"):
                    Q.validate_loader_baseline(self.source, self.baseline)
                (root / "unexpected").unlink()

    def test_changed_templates_and_host_lock_are_rejected(self):
        for name in (Q.NOTICES_FILE, Q.THIRD_PARTY_INVENTORY, Q.RUNTIME_INVENTORY,
                     Q.SOURCE_DOCUMENTS, Q.CONFIG_PATH, "Package.resolved"):
            with self.subTest(path=name):
                old = (self.source / name).read_bytes()
                self.write(name, old + b"\n")
                self.commit("mutated template")
                with self.assertRaisesRegex(ValueError, "template differs"):
                    Q.validate_loader_baseline(self.source, self.baseline)
                self.write(name, old)
                self.commit("restore template")

    def test_nonancestor_and_same_checkout_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "separate clean ancestor"):
            Q.validate_loader_baseline(self.source, self.source)
        other = self.root / "unrelated"
        other.mkdir()
        self.git("init", "-q", root=other)
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "unrelated", root=other)
        with self.assertRaisesRegex(ValueError, "strict ancestor"):
            Q.validate_loader_baseline(self.source, other)

    def test_source_drift_and_added_scope_are_rejected(self):
        manifest, fetch = self.captured()
        self.write("Guest/HostwrightNetfilter/source0.go", b"changed source\n")
        with self.assertRaisesRegex(ValueError, "differs from captured source"):
            Q.refresh_loader_locks(self.source, self.runtime, manifest, fetch)
        self.write("Guest/HostwrightNetfilter/source0.go", b"package main\n")
        self.write("Guest/HostwrightNetfilter/extra.go", b"package main\n")
        self.commit("added source")
        manifest, fetch = self.captured()
        with self.assertRaisesRegex(ValueError, "20-file source scope"):
            Q.refresh_loader_locks(self.source, self.runtime, manifest, fetch)

    def test_duplicate_versions_and_malformed_checksums_are_rejected(self):
        for checksum in (self.new_sum * 2, b"invalid\n", self.new_sum.replace(b"h1:", b"h2:")):
            with self.subTest(checksum=checksum):
                self.write("Guest/HostwrightNetfilter/go.sum", checksum)
                self.commit("invalid lock")
                manifest, fetch = self.captured()
                with self.assertRaises(ValueError):
                    Q.refresh_loader_locks(self.source, self.runtime, manifest, fetch)

    def test_default_binding_still_rejects_dependency_drift(self):
        manifest, fetch = self.captured()
        with self.assertRaisesRegex(ValueError, "guest Go module/checksum source drift"):
            Q.verify_root_guest_bindings(self.source, {}, self.runtime, manifest, fetch)

    def test_wrong_source_commit_or_captured_license_is_rejected(self):
        manifest, fetch = self.captured()
        wrong_commit = dict(manifest, sourceCommit="f" * 40)
        with self.assertRaisesRegex(ValueError, "exact captured source commit"):
            Q.refresh_loader_locks(self.source, self.runtime, wrong_commit, fetch)
        (self.root / f"capture-{self.capture_number}" / "license.txt").write_bytes(b"changed license\n")
        with self.assertRaisesRegex(ValueError, "evidence bytes mismatch"):
            Q.refresh_loader_locks(self.source, self.runtime, manifest, fetch)

    def test_require_blocks_exclude_checksum_cache_only_entries(self):
        module = b"module example.invalid/fixture\ngo 1.26.0\nrequire (\nexample.invalid/dependency v2.0.0 // indirect\n)\n"
        cached = b"example.invalid/cache-only v9.0.0 h1:" + b"A" * 43 + b"=\n"
        result = Q.declared_go_dependencies(module, self.new_sum + self.old_sum + cached)
        self.assertEqual([(item["module"], item["version"]) for item in result],
                         [("example.invalid/dependency", "v2.0.0")])

    def test_ambiguous_unsupported_or_unchecksummed_requires_are_rejected(self):
        require = b"require example.invalid/dependency v2.0.0\n"
        for module in (require * 2, require + require.replace(b"v2.0.0", b"v1.0.0"),
                       require + b"replace example.invalid/dependency => ../local\n",
                       b"require (\nexample.invalid/dependency v2.0.0\n", require.replace(b"v2.0.0", b"v3.0.0"),
                       b"require example.invalid/dependency\n"):
            with self.subTest(module=module), self.assertRaises(ValueError):
                Q.declared_go_dependencies(module, self.new_sum)

    def test_go_license_aliases_follow_captured_versions_and_preserve_old_text(self):
        manifest, fetch = self.captured()
        project = manifest["sourceProjects"][0]
        dependency = dict(module="example.invalid/dependency", version="v2.0.0", checksum="h1:" + "A" * 43 + "=")
        loader = dict(modules=[dict(project="hostwright", buildInfo=list(dependency.values()))])
        notices = bytearray(b"Prior license\n")
        records = [dict(category="runtime-go-license", sourcePath="guest-go/example.invalid/dependency@v1.0.0/LICENSE",
                        offsetBytes=0, sizeBytes=len(notices), sha256=Q.sha(notices))]
        old_bytes = bytes(notices)
        Q.refresh_go_documents(notices, records, [dependency], loader, {"hostwright": project}, fetch, "a" * 64, [])
        self.assertTrue(bytes(notices).startswith(old_bytes))
        self.assertEqual(records[0]["category"], "runtime-upstream-go-license")
        self.assertEqual(records[1]["sourcePath"], "guest-go/example.invalid/dependency@v2.0.0/LICENSE")
        self.assertEqual(records[1]["sha256"], Q.sha(b"Fixture source license\n"))

    def test_resolved_only_go_pin_requires_unchanged_tuple_and_exact_receipt(self):
        dependency = dict(module="example.invalid/dependency", version="v1.0.0", checksum="h1:" + "A" * 43 + "=")
        record = dict(category="runtime-go-license", sourcePath="guest-go/example.invalid/dependency@v1.0.0/LICENSE")
        Q.refresh_go_documents(bytearray(), [record], [dependency], dict(modules=[]), {}, None, "a" * 64, [dependency])
        for records, baseline in (([], [dependency]), ([record], []),
                                  ([record], [dict(dependency, checksum="h1:" + "B" * 43 + "=")])):
            with self.subTest(records=records, baseline=baseline), self.assertRaisesRegex(ValueError, "exact license receipt"):
                Q.refresh_go_documents(bytearray(), records, [dependency], dict(modules=[]), {}, None, "a" * 64, baseline)


if __name__ == "__main__":
    unittest.main()
