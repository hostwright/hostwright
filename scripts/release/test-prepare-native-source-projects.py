#!/usr/bin/env python3
import copy
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


P = load("native_source_preparer", "prepare-native-source-projects.py")
S = load("source_capture", "capture-runtime-source.py")


class NativeSourcePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repository = self.root / "repository"
        self.repository.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repository)], check=True)
        self.original = {"main.c": b"int value = 1;\n", "COPYING": b"Explicit fixture license text\n",
                         "NOTICE": b"Exact fixture attribution\n"}
        for name, data in self.original.items():
            (self.repository / name).write_bytes(data)
        (self.repository / "license-link").symlink_to("COPYING")
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-qm", "source")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()
        S.capture(self.repository, self.commit, self.inputs / "capture")
        self.metadata = [dict(identity="sdk/example", sourceDirectory="capture", spdx="MIT",
                              licenses=["COPYING"], notices=["NOTICE"], patches=[])]
        self.output = self.root / "output"

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repository), *args])

    def prepare(self, output=None):
        return P.prepare(self.inputs, self.metadata, output or self.output)

    def test_real_git_patch_license_and_source_bytes_are_bound(self):
        (self.repository / "main.c").write_bytes(b"int value = 2;\n")
        (self.repository / "COPYING").write_bytes(b"Explicit fixture license text\nAdditional notice\n")
        patch = self.git("diff", "HEAD", "--")
        (self.inputs / "build.patch").write_bytes(patch)
        self.metadata[0]["patches"] = ["build.patch"]
        projects = self.prepare()
        self.assertEqual(projects, P.V.parse((self.output / "projects.json").read_bytes()))
        project = projects[0]
        leaves = P.V.source_project(project, lambda name: (self.output / name).read_bytes())
        self.assertEqual(leaves["main.c"]["sha256"], P.V.digest(b"int value = 2;\n"))
        before = dict(self.original, **{"license-link": b"COPYING"})
        after = dict(before, **{"main.c": b"int value = 2;\n", "COPYING": b"Explicit fixture license text\nAdditional notice\n"})
        self.assertEqual(project["patches"][0]["beforeInventorySHA256"], P.inventory_digest(before))
        self.assertEqual(project["patches"][0]["afterInventorySHA256"], P.inventory_digest(after))
        self.assertEqual((self.output / project["licenses"][0]["path"]).read_bytes(), after["COPYING"])
        self.assertEqual((self.output / project["archive"]["path"]).read_bytes(),
                         (self.inputs / "capture/source.tar.gz").read_bytes())
        self.assertEqual(project["commit"], self.commit)
        self.assertEqual(projects, self.prepare(self.root / "second"))

    def test_same_revision_can_have_distinct_declared_component_identities(self):
        other = dict(self.metadata[0], identity="swiftpm/example")
        self.metadata.append(other)
        projects = self.prepare()
        self.assertEqual([p["identity"] for p in projects], ["sdk/example", "swiftpm/example"])
        self.assertEqual({p["commit"] for p in projects}, {self.commit})
        self.assertNotEqual(projects[0]["archive"]["path"], projects[1]["archive"]["path"])
        for project in projects:
            self.assertEqual(project["licenses"][0]["component"], project["identity"])

    def test_license_declarations_are_required_and_never_guessed(self):
        for field, value in (("licenses", []), ("notices", []), ("licenses", ["LICENSE"]),
                             ("licenses", ["license-link"]), ("spdx", "LicenseRef-Unknown")):
            metadata = copy.deepcopy(self.metadata)
            metadata[0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                P.prepare(self.inputs, metadata, self.output)
            self.assertFalse(self.output.exists())

    def test_source_tampering_fails_before_publishing(self):
        filename = self.inputs / "capture/source.tar.gz"
        filename.write_bytes(filename.read_bytes() + b"tampered")
        with self.assertRaisesRegex(ValueError, "captured native source bytes mismatch"):
            self.prepare()
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.glob(".native-source-projects-*")))

    def test_unsupported_and_wrong_context_patches_fail_closed(self):
        for patch in (b"GIT binary patch\nliteral 5\n",
                      b"new file mode 100644\n--- /dev/null\n+++ b/new.c\n@@ -0,0 +1 @@\n+new\n",
                      b"--- a/main.c\n+++ b/main.c\n@@ -1 +1 @@\n-wrong\n+new\n",
                      b"--- a/license-link\n+++ b/license-link\n@@ -1 +1 @@\n-COPYING\n+NOTICE\n"):
            with self.subTest(patch=patch):
                (self.inputs / "build.patch").write_bytes(patch)
                self.metadata[0]["patches"] = ["build.patch"]
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertFalse(self.output.exists())

    def test_duplicate_identity_path_escape_and_input_symlinks_are_rejected(self):
        duplicate = [self.metadata[0], self.metadata[0]]
        with self.assertRaisesRegex(ValueError, "duplicate native source identity"):
            P.prepare(self.inputs, duplicate, self.output)
        for field, value in (("sourceDirectory", "../repository"), ("patches", ["../escape.patch"]),
                             ("licenses", ["../COPYING"])):
            metadata = copy.deepcopy(self.metadata)
            metadata[0][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "unsafe provenance path"):
                P.prepare(self.inputs, metadata, self.output)
        (self.inputs / "linked").symlink_to(self.inputs / "capture", target_is_directory=True)
        self.metadata[0]["sourceDirectory"] = "linked"
        with self.assertRaisesRegex(ValueError, "symlink in native source input"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_complete_submodule_catalog_is_required(self):
        child_commit = self.commit
        self.git("update-index", "--add", "--cacheinfo", "160000," + child_commit + ",dependency")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-qm", "submodule")
        parent_commit = self.git("rev-parse", "HEAD").decode().strip()
        S.capture(self.repository, parent_commit, self.inputs / "parent", {"dependency": "child"})
        self.metadata[0]["sourceDirectory"] = "parent"
        self.metadata[0]["identity"] = "parent"
        with self.assertRaisesRegex(ValueError, "submodule lacks exact captured source project"):
            self.prepare()
        self.assertFalse(self.output.exists())
        self.metadata.append(dict(self.metadata[0], identity="child", sourceDirectory="capture"))
        projects = self.prepare()
        parent = next(p for p in projects if p["identity"] == "parent")
        self.assertEqual(parent["submodules"], [dict(path="dependency", project="child", commit=child_commit)])


if __name__ == "__main__":
    unittest.main()
