#!/usr/bin/env python3
import copy
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


A = load("reviewed_sources", "prepare-reviewed-native-sources.py")
SDK = load("sdk_inputs", "capture-swift-sdk-build-inputs.py")
PACKAGES = load("package_sources", "capture-package-sources.py")
V = A.V


class ReviewedNativeSourcesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.sources = self.root / "sources"
        self.repository = self.sources / "component"
        self.repository.mkdir(parents=True)
        self.original = {"Sources/main.c": b"int value = 1;\n", "Sources/private/other.c": b"int hidden = 1;\n",
                         "Tests/test.c": b"int test = 1;\n", "LICENSE": b"Explicit reviewed MIT fixture license text\n",
                         "NOTICE": b"Exact original component attribution notice\n"}
        for name, data in self.original.items():
            target = self.repository / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (self.repository / "Sources/link.c").symlink_to("main.c")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-qm", "fixture")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        self.build = self.root / "build"
        self.build.mkdir()
        (self.build / "compile_commands.json").write_bytes(b"[]\n")
        (self.build / "main.o").write_bytes(b"retained test object\n")
        self.archive = self.root / "sdk.tar.gz"
        self.archive.write_bytes(b"test SDK archive bytes\n")
        self.patched = b"int value = 2;\n"
        (self.repository / "Sources/main.c").write_bytes(self.patched)
        self.patch = self.git("diff", "HEAD", "--")
        self.sdk = self.root / "sdk-inputs"
        self.capture_sdk(self.sdk)
        self.ingredients = self.root / "ingredients"
        evidence = self.ingredients / "evidence"
        (evidence / "source-trees").mkdir(parents=True)
        for name in ("linux", "containerization"):
            SDK.SOURCE.capture(self.repository, self.commit, evidence / "source-trees" / name)
        (evidence / "applied.patch").write_bytes(self.patch)
        self.patches = {"linux": [], "containerization": [self.record("applied.patch", self.patch)]}
        self.catalog = dict(kind="hostwright.runtime-native-source-licenses.v1", schemaVersion=1,
            status="reviewed-declarations-not-link-qualified", sdk=[self.declaration("swift-sdk/component", "component")],
            guest=[], kernel=self.declaration("linux", "source-trees/linux"),
            containerization=self.declaration("containerization", "source-trees/containerization"), excluded=[])
        self.source_map = [dict(objectSHA256=V.digest(b"actual fixture object"), sourceFiles=[
            dict(project="swift-sdk/component", path="Sources/main.c", sha256=V.digest(self.patched))])]
        self.output = self.root / "prepared"

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repository), *args])

    def capture_sdk(self, output):
        return SDK.capture(self.sources, self.build, self.archive,
                           [dict(destination="component", commit=self.commit)], output)

    @staticmethod
    def record(name, data):
        return dict(path=name, sha256=V.digest(data), sizeBytes=len(data))

    def declaration(self, identity, destination):
        documents = [dict(self.record(name, self.original[name]), gitBlobSHA1=V.git_object("blob", self.original[name]))
                     for name in ("LICENSE", "NOTICE")]
        return dict(identity=identity, destination=destination, commit=self.commit, spdx="MIT",
                    licenses=["LICENSE"], notices=["NOTICE"], documents=documents,
                    allowedSourcePrefixes=["Sources/"], excludedSourcePrefixes=["Sources/private/"])

    def prepare(self, **kwargs):
        return A.prepare(self.catalog, self.source_map, self.output, sdk_inputs=self.sdk, **kwargs)

    def assert_unpublished(self):
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.glob(".reviewed-native-sources-*")))

    def generated_headers(self):
        root = self.root / "mapping"
        root.mkdir()
        inputs = {"generated/config.h": b"#define BUILD_CONFIG 1\n",
                  "generated/compile_commands.json": V.canonical([dict(directory="/build",
                      arguments=["clang", "-c", "/source/main.c", "-o", "main.o"], file="/source/main.c")]),
                  "generated/main.d": b"main.o: /source/main.c /build/config.h\n"}
        for name, data in inputs.items():
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        self.source_map[0]["generatedHeaders"] = [dict(originalPath="/build/config.h",
            file=self.record("generated/config.h", inputs["generated/config.h"]),
            compilerArguments=["clang", "-c", "/source/main.c", "-o", "main.o"], cwd="/build",
            evidence=dict(path="/build/compile_commands.json", file="/source/main.c", dependencyPath="/build/main.d"),
            retainedEvidence=[dict(originalPath="/build/" + Path(name).name, file=self.record(name, data))
                              for name, data in inputs.items() if not name.endswith("config.h")])]
        return root, inputs

    def compiler_input_sidecar(self):
        root, files = self.generated_headers()
        nested = root / "nested"
        nested.mkdir()
        (root / "generated").rename(nested / "generated")
        row = self.source_map[0]
        inputs = dict(objectSHA256=row["objectSHA256"], translationUnits=copy.deepcopy(row["sourceFiles"]),
            sourceFiles=copy.deepcopy(row["sourceFiles"]) + [dict(project="swift-sdk/component",
                path="Sources/private/other.c", sha256=V.digest(self.original["Sources/private/other.c"]))],
            generatedHeaders=row.pop("generatedHeaders"))
        filename = root / "nested/compiler-inputs.json"
        filename.write_bytes(V.canonical(inputs))
        row["compilerInputs"] = self.record("nested/compiler-inputs.json", filename.read_bytes())
        return root, inputs, files

    def test_compact_inputs_preserve_full_sources_and_relative_bound_evidence(self):
        root, inputs, files = self.compiler_input_sidecar()
        inputs["translationUnits"] = copy.deepcopy(inputs["sourceFiles"])
        data = V.canonical(inputs)
        (root / "nested/compiler-inputs.json").write_bytes(data)
        self.source_map[0]["compilerInputs"] = self.record("nested/compiler-inputs.json", data)
        self.catalog["sdk"][0]["excludedSourcePrefixes"] = []
        original = copy.deepcopy(self.source_map)
        self.prepare(source_map_root=root)
        result = V.parse((self.output / "source-map.json").read_bytes())
        self.assertEqual(result[0]["sourceFiles"], original[0]["sourceFiles"])
        record = result[0]["compilerInputs"]
        self.assertEqual(record["path"], "source-map/nested/compiler-inputs.json")
        retained = V.bound(record, lambda name: (self.output / name).read_bytes())
        self.assertEqual(retained, V.canonical(inputs))
        parent = (self.output / record["path"]).parent
        for name, data in files.items():
            self.assertEqual((parent / name).read_bytes(), data)
        _, selected = A.selected_sources(result, self.output)
        self.assertEqual(set(selected["swift-sdk/component"]), {"Sources/main.c", "Sources/private/other.c"})
        self.assertEqual(self.source_map, original)

    def test_compact_omissions_cannot_hide_excluded_or_tampered_source(self):
        root, inputs, _ = self.compiler_input_sidecar()
        with self.assertRaisesRegex(ValueError, "excluded from reviewed scope"):
            self.prepare(source_map_root=root)
        self.assert_unpublished()
        self.catalog["sdk"][0]["excludedSourcePrefixes"] = []
        inputs["sourceFiles"][1]["sha256"] = "0" * 64
        data = V.canonical(inputs)
        (root / "nested/compiler-inputs.json").write_bytes(data)
        self.source_map[0]["compilerInputs"] = self.record("nested/compiler-inputs.json", data)
        with self.assertRaisesRegex(ValueError, "captured patched bytes"):
            self.prepare(source_map_root=root)
        self.assert_unpublished()

    def test_compact_inputs_and_nested_evidence_reject_tampering_atomically(self):
        root, inputs, files = self.compiler_input_sidecar()
        self.catalog["sdk"][0]["excludedSourcePrefixes"] = []
        for name, original in {"compiler-inputs.json": V.canonical(inputs), **files}.items():
            filename = root / "nested" / name
            filename.write_bytes(original + b"tampered")
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "evidence bytes mismatch"):
                self.prepare(source_map_root=root)
            self.assert_unpublished()
            filename.write_bytes(original)
        with self.assertRaisesRegex(ValueError, "requires a source map root"):
            self.prepare()
        self.assert_unpublished()
        self.source_map[0]["compilerInputs"]["path"] = "../compiler-inputs.json"
        with self.assertRaisesRegex(ValueError, "unsafe provenance path"):
            self.prepare(source_map_root=root)
        self.assert_unpublished()

    def test_compact_nested_evidence_path_escape_and_symlink_fail(self):
        root, inputs, _ = self.compiler_input_sidecar()
        self.catalog["sdk"][0]["excludedSourcePrefixes"] = []
        inputs["generatedHeaders"][0]["file"]["path"] = "../escape.h"
        data = V.canonical(inputs)
        (root / "nested/compiler-inputs.json").write_bytes(data)
        self.source_map[0]["compilerInputs"] = self.record("nested/compiler-inputs.json", data)
        with self.assertRaisesRegex(ValueError, "unsafe provenance path"):
            self.prepare(source_map_root=root)
        self.assert_unpublished()
        inputs["generatedHeaders"][0]["file"]["path"] = "generated/config.h"
        data = V.canonical(inputs)
        (root / "nested/compiler-inputs.json").write_bytes(data)
        self.source_map[0]["compilerInputs"] = self.record("nested/compiler-inputs.json", data)
        header = root / "nested/generated/config.h"
        header.unlink()
        header.symlink_to(root / "nested/generated/main.d")
        with self.assertRaisesRegex(ValueError, "symlink in native source input"):
            self.prepare(source_map_root=root)
        self.assert_unpublished()

    def test_compact_inputs_bind_object_units_and_component_set(self):
        root, original, _ = self.compiler_input_sidecar()
        self.catalog["sdk"][0]["excludedSourcePrefixes"] = []
        for change in ("object", "units", "component"):
            inputs = copy.deepcopy(original)
            if change == "object":
                inputs["objectSHA256"] = "0" * 64
            elif change == "units":
                inputs["translationUnits"] = [dict(inputs["sourceFiles"][1], sha256="0" * 64)]
            else:
                inputs["sourceFiles"][1]["project"] = "unrepresented-component"
            data = V.canonical(inputs)
            (root / "nested/compiler-inputs.json").write_bytes(data)
            self.source_map[0]["compilerInputs"] = self.record("nested/compiler-inputs.json", data)
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "compiler input|native source|translation units"):
                self.prepare(source_map_root=root)
            self.assert_unpublished()

    def test_generated_header_records_round_trip_with_cli_default_map_root(self):
        root, inputs = self.generated_headers()
        self.source_map.append(copy.deepcopy(self.source_map[0]))
        original = copy.deepcopy(self.source_map)
        map_file, catalog_file = root / "map.json", self.root / "catalog.json"
        map_file.write_bytes(V.canonical(self.source_map))
        catalog_file.write_bytes(V.canonical(self.catalog))
        subprocess.run([sys.executable, str(HERE / "prepare-reviewed-native-sources.py"),
                        "--sdk-inputs", str(self.sdk), "--catalog", str(catalog_file),
                        "--source-map", str(map_file), "--output", str(self.output)], check=True)
        output_map = V.parse((self.output / "source-map.json").read_bytes())
        header = output_map[0]["generatedHeaders"][0]
        old_header = original[0]["generatedHeaders"][0]
        for field in ("originalPath", "compilerArguments", "cwd", "evidence"):
            self.assertEqual(header[field], old_header[field])
        records = [header["file"]] + [item["file"] for item in header["retainedEvidence"]]
        for record in records:
            name = record["path"].removeprefix("source-map/")
            self.assertNotEqual(name, record["path"])
            self.assertEqual(V.bound(record, lambda path: (self.output / path).read_bytes()), inputs[name])
        self.assertEqual(original, self.source_map)
        self.assertEqual(original, V.parse(map_file.read_bytes()))
        self.assertEqual(output_map[0], output_map[1])
        self.assertEqual(len(list((self.output / "source-map/generated").iterdir())), len(inputs))

    def test_conflicting_shared_generated_header_records_fail_atomically(self):
        root, inputs = self.generated_headers()
        self.source_map.append(copy.deepcopy(self.source_map[0]))
        self.source_map[1]["generatedHeaders"][0]["file"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "conflicting source map evidence"):
            self.prepare(source_map_root=root)
        self.assert_unpublished()

    def test_generated_headers_require_existing_bound_bytes_and_root(self):
        root, inputs = self.generated_headers()
        with self.assertRaisesRegex(ValueError, "requires a source map root"):
            self.prepare()
        self.assert_unpublished()
        for name, data in inputs.items():
            (root / name).write_bytes(data + b"tampered")
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "evidence bytes mismatch"):
                self.prepare(source_map_root=root)
            self.assert_unpublished()
            (root / name).write_bytes(data)
        (root / "generated/config.h").unlink()
        with self.assertRaisesRegex(ValueError, "missing regular native source input"):
            self.prepare(source_map_root=root)
        self.assert_unpublished()

    def test_generated_header_path_escape_and_symlink_are_rejected(self):
        root, inputs = self.generated_headers()
        record = self.source_map[0]["generatedHeaders"][0]["file"]
        record["path"] = "../escape.h"
        with self.assertRaisesRegex(ValueError, "unsafe provenance path"):
            self.prepare(source_map_root=root)
        self.assert_unpublished()
        record["path"] = "generated/config.h"
        (root / record["path"]).unlink()
        (root / record["path"]).symlink_to(root / "generated/main.d")
        with self.assertRaisesRegex(ValueError, "symlink in native source input"):
            self.prepare(source_map_root=root)
        self.assert_unpublished()

    def test_real_sdk_and_native_captures_preserve_actual_patches(self):
        self.source_map[0]["sourceFiles"].append(dict(project="containerization", path="Sources/main.c",
                                                    sha256=V.digest(self.patched)))
        projects = self.prepare(ingredients=self.ingredients, native_patches=self.patches)
        self.assertEqual({p["identity"] for p in projects}, {"linux", "containerization", "swift-sdk/component"})
        self.assertEqual(projects, V.parse((self.output / "projects.json").read_bytes()))
        self.assertEqual(self.source_map, V.parse((self.output / "source-map.json").read_bytes()))
        for project in projects:
            leaves = V.source_project(project, lambda name: (self.output / name).read_bytes())
            expected = self.original["Sources/main.c"] if project["identity"] == "linux" else self.patched
            self.assertEqual(leaves["Sources/main.c"]["sha256"], V.digest(expected))
            self.assertEqual(len(project["patches"]), 0 if project["identity"] == "linux" else 1)
            self.assertEqual(project["licenses"][0]["sourcePath"], "LICENSE")

    def test_sdk_supplemental_license_patch_is_bound_and_replayed(self):
        build_path = self.sdk / "build-inputs.json"
        build = V.parse(build_path.read_bytes())
        build["sourceProjects"][0].pop("workingTreePatch")
        build_path.write_bytes(V.canonical(build))
        patch_path = self.sdk / "review-patches" / "license.patch"
        patch_path.parent.mkdir()
        patch_path.write_bytes(self.patch)
        projects = self.prepare(sdk_source_patches={"swift-sdk/component": [self.record(
            "review-patches/license.patch", self.patch)]})
        project = projects[0]
        leaves = V.source_project(project, lambda name: (self.output / name).read_bytes())
        self.assertEqual(leaves["Sources/main.c"]["sha256"], V.digest(self.patched))
        self.assertEqual(len(project["patches"]), 1)

    def test_sdk_supplemental_patch_rejects_missing_project_or_bytes(self):
        with self.assertRaisesRegex(ValueError, "SDK source patch project is missing"):
            self.prepare(sdk_source_patches={"missing": [self.record("missing.patch", b"diff\n")]})
        build_path = self.sdk / "build-inputs.json"
        build = V.parse(build_path.read_bytes())
        build["sourceProjects"][0].pop("workingTreePatch")
        build_path.write_bytes(V.canonical(build))
        patch_path = self.sdk / "review-patches" / "license.patch"
        patch_path.parent.mkdir()
        patch_path.write_bytes(b"tampered\n")
        with self.assertRaisesRegex(ValueError, "evidence bytes mismatch"):
            self.prepare(sdk_source_patches={"swift-sdk/component": [self.record(
                "review-patches/license.patch", self.patch)]})
        self.assert_unpublished()

    def test_actual_package_catalog_is_selected_without_unrelated_projects(self):
        checkouts = self.root / "checkouts"
        checkouts.mkdir()
        subprocess.run(["git", "clone", "-q", str(self.repository), str(checkouts / "guest-package")], check=True)
        lock = self.root / "Package.resolved"
        lock.write_bytes(V.canonical(dict(version=3, pins=[dict(identity="guest-package", kind="remoteSourceControl",
                                                              state=dict(revision=self.commit))])))
        PACKAGES.capture_packages(lock, checkouts, self.ingredients / "evidence/source-trees/vminit-packages")
        self.catalog["guest"].append(self.declaration("guest-package", "guest-package"))
        self.source_map[0]["sourceFiles"] = [dict(project="guest-package", path="Sources/main.c",
                                                 sha256=V.digest(self.original["Sources/main.c"]))]
        projects = self.prepare(ingredients=self.ingredients, native_patches=self.patches)
        self.assertEqual({p["identity"] for p in projects}, {"guest-package", "linux"})

    def test_changed_commit_or_reviewed_document_digest_fails(self):
        original = copy.deepcopy(self.catalog)
        for change in ("commit", "document"):
            self.catalog = copy.deepcopy(original)
            if change == "commit":
                self.catalog["sdk"][0]["commit"] = "0" * 40
            else:
                self.catalog["sdk"][0]["documents"][0]["sha256"] = "0" * 64
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "reviewed"):
                self.prepare()
            self.assert_unpublished()

    def test_selected_excluded_and_missing_projects_fail(self):
        for identity in ("unreviewed", "missing"):
            self.catalog["excluded"] = [dict(identity="unreviewed", reason="terms not reviewed")]
            self.source_map[0]["sourceFiles"][0]["project"] = identity
            with self.subTest(identity=identity), self.assertRaisesRegex(ValueError, "excluded|missing"):
                self.prepare()
            self.assert_unpublished()

    def test_selected_sources_must_match_machine_readable_scopes(self):
        for name in ("Tests/test.c", "Sources/private/other.c"):
            self.source_map[0]["sourceFiles"][0].update(path=name, sha256=V.digest(self.original[name]))
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "reviewed scope"):
                self.prepare()
            self.assert_unpublished()
        row = self.catalog["sdk"][0]
        row.pop("allowedSourcePrefixes")
        row.pop("excludedSourcePrefixes")
        row["scope"] = "Only a subset is reviewed"
        with self.assertRaisesRegex(ValueError, "explicit source prefixes"):
            self.prepare()

    def test_selected_bytes_and_links_are_checked_after_patch_replay(self):
        for name, digest in (("Sources/main.c", V.digest(self.original["Sources/main.c"])),
                             ("Sources/link.c", V.digest(b"main.c"))):
            self.source_map[0]["sourceFiles"][0].update(path=name, sha256=digest)
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "captured patched bytes"):
                self.prepare()
            self.assert_unpublished()

    def test_patch_cannot_silently_change_reviewed_license(self):
        (self.repository / "LICENSE").write_bytes(self.original["LICENSE"] + b"changed license condition\n")
        self.sdk = self.root / "sdk-license-change"
        self.capture_sdk(self.sdk)
        with self.assertRaisesRegex(ValueError, "changes reviewed license"):
            self.prepare()
        self.assert_unpublished()

    def test_explicitly_reviewed_license_patch_binds_base_and_final_documents(self):
        revised = self.original["LICENSE"] + b"Reviewed complete upstream notice\n"
        (self.repository / "LICENSE").write_bytes(revised)
        self.sdk = self.root / "sdk-reviewed-license"
        self.capture_sdk(self.sdk)
        declaration = self.catalog["sdk"][0]
        declaration["patchedDocuments"] = copy.deepcopy(declaration["documents"])
        declaration["patchedDocuments"][0] = dict(self.record("LICENSE", revised),
                                                   gitBlobSHA1=V.git_object("blob", revised))
        projects = self.prepare()
        self.assertEqual((self.output / projects[0]["licenses"][0]["path"]).read_bytes(), revised)
        self.assertEqual(len(projects[0]["patches"]), 1)

    def test_native_patches_require_explicit_ledger_and_bound_bytes(self):
        with self.assertRaisesRegex(ValueError, "explicit native applied-patch ledger"):
            self.prepare(ingredients=self.ingredients)
        self.assert_unpublished()
        self.patches["linux"] = [self.record("applied.patch", b"different patch")]
        with self.assertRaisesRegex(ValueError, "mismatch"):
            self.prepare(ingredients=self.ingredients, native_patches=self.patches)
        self.assert_unpublished()

    def test_capture_catalog_drift_and_archive_tampering_fail(self):
        filename = self.sdk / "build-inputs.json"
        original = filename.read_bytes()
        capture = V.parse(original)
        capture["sourceProjects"][0]["source"]["commit"] = "0" * 40
        filename.write_bytes(V.canonical(capture))
        with self.assertRaisesRegex(ValueError, "source.json"):
            self.prepare()
        self.assert_unpublished()
        filename.write_bytes(original)
        archive = self.sdk / "source-trees/component/source.tar.gz"
        archive.write_bytes(archive.read_bytes() + b"tampered")
        with self.assertRaisesRegex(ValueError, "bytes mismatch"):
            self.prepare()
        self.assert_unpublished()

    def test_path_escape_duplicate_identities_and_symlink_inputs_fail(self):
        self.source_map[0]["sourceFiles"][0]["path"] = "../LICENSE"
        with self.assertRaisesRegex(ValueError, "unsafe provenance path"):
            self.prepare()
        self.source_map[0]["sourceFiles"][0]["path"] = "Sources/main.c"
        self.catalog["sdk"].append(copy.deepcopy(self.catalog["sdk"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate reviewed"):
            self.prepare()
        self.catalog["sdk"].pop()
        link = self.root / "sdk-link"
        link.symlink_to(self.sdk, target_is_directory=True)
        self.sdk = link
        with self.assertRaisesRegex(ValueError, "unsafe source capture root"):
            self.prepare()
        self.assert_unpublished()

    def test_unresolved_object_report_is_not_a_complete_selection(self):
        self.source_map = dict(sourceMap=self.source_map, unresolved=[dict(member="unmapped.o")])
        with self.assertRaisesRegex(ValueError, "unresolved sources"):
            self.prepare()
        self.assert_unpublished()


if __name__ == "__main__":
    unittest.main()
