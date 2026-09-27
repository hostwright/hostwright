#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


P = load("native_patches", "capture-native-patches.py")
S = load("patch_source_capture", "capture-runtime-source.py")


class NativePatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repository = self.root / "repository"
        self.repository.mkdir()
        self.git("init", "-q")
        (self.repository / "main.c").write_text("int value = 1;\n")
        (self.repository / "other.c").write_text("int other = 0;\n")
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-qm", "source")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        self.source = self.root / "source"
        S.capture(self.repository, self.commit, self.source)
        self.tree = self.root / "build"
        shutil.copytree(self.repository, self.tree, ignore=shutil.ignore_patterns(".git"))
        self.patches = self.root / "6.18.x"
        self.patches.mkdir()
        self.first = self.patches / "0001-first.patch"
        self.second = self.patches / "0002-second.patch"
        self.first.write_bytes(b"diff --git a/main.c b/main.c\n--- a/main.c\n+++ b/main.c\n@@ -1 +1 @@\n-int value = 1;\n+int value = 2;\n")
        self.second.write_bytes(b"diff --git a/main.c b/main.c\n--- a/main.c\n+++ b/main.c\n@@ -1 +1 @@\n-int value = 2;\n+int value = 3;\n")
        subprocess.run(["git", "apply", str(self.first)], cwd=self.tree, check=True)
        subprocess.run(["git", "apply", str(self.second)], cwd=self.tree, check=True)
        self.evidence = self.root / "evidence"
        self.evidence.mkdir()
        self.output = self.evidence / "native-patches.json"
        self.log = self.root / "setup.log"
        self.log.write_text("INFO: Apply patches from /original/6.18.x\nINFO: Found 2 patches\n"
                            "INFO: Apply /original/6.18.x/0001-first.patch\npatching file main.c\n"
                            "INFO: Apply /original/6.18.x/0002-second.patch\npatching file main.c\n"
                            "Kernel source ready: /original/kernel\n")

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.repository), *arguments])

    def capture(self, patches=None):
        patches = P.kernel_patches(self.log, self.patches) if patches is None else patches
        return P.capture(self.repository, self.source, self.tree, self.evidence, "linux", patches, self.output)

    def test_ordered_real_git_patch_replay_matches_all_tracked_build_sources(self):
        original_objects = set((self.repository / ".git/objects").rglob("*"))
        (self.tree / ".config").write_text("CONFIG_ARM64=y\n")
        result = self.capture()
        self.assertEqual(result, P.V.parse(self.output.read_bytes()))
        self.assertEqual(len(result["linux"]), 2)
        for record, patch in zip(result["linux"], (self.first, self.second)):
            self.assertEqual(P.V.bound(record, lambda name: (self.evidence / name).read_bytes()), patch.read_bytes())
        self.assertEqual(self.git("status", "--porcelain"), b"")
        self.assertEqual(set((self.repository / ".git/objects").rglob("*")), original_objects)

    def test_unlisted_source_difference_is_rejected_before_publishing(self):
        (self.tree / "other.c").write_text("int other = 7;\n")
        with self.assertRaisesRegex(ValueError, "differs from the applied patch ledger: other.c"):
            self.capture()
        self.assertFalse(self.output.exists())
        self.assertFalse((self.evidence / "native-patches").exists())

    def test_patch_order_wrong_context_and_new_files_fail_closed(self):
        with self.assertRaisesRegex(ValueError, "source patch context mismatch"):
            self.capture([self.second, self.first])
        self.first.write_bytes(b"diff --git a/new.c b/new.c\nnew file mode 100644\n--- /dev/null\n+++ b/new.c\n@@ -0,0 +1 @@\n+new\n")
        with self.assertRaisesRegex(ValueError, "unsupported binary/file-mode source patch"):
            self.capture([self.first])
        self.assertFalse(self.output.exists())

    def test_incomplete_setup_or_wrong_patch_count_is_rejected(self):
        original = self.log.read_text()
        self.log.write_text(original.replace("Kernel source ready: /original/kernel\n", ""))
        with self.assertRaisesRegex(ValueError, "did not finish successfully"):
            self.capture()
        self.log.write_text(original.replace("Found 2", "Found 3"))
        with self.assertRaisesRegex(ValueError, "incomplete or ambiguous"):
            self.capture()
        self.assertFalse(self.output.exists())

    def test_empty_ledger_still_checks_complete_source_tree(self):
        with self.assertRaisesRegex(ValueError, "differs from the applied patch ledger: main.c"):
            self.capture([])
        (self.tree / "main.c").write_bytes((self.repository / "main.c").read_bytes())
        self.assertEqual(self.capture([]), {"linux": []})

    def test_captured_git_binding_and_file_modes_are_checked(self):
        (self.tree / "other.c").chmod(0o755)
        with self.assertRaisesRegex(ValueError, "differs from the applied patch ledger: other.c"):
            self.capture()
        (self.tree / "other.c").chmod(0o644)
        source = P.V.parse((self.source / "source.json").read_bytes())
        source["commit"] = "f" * 40
        (self.source / "source.json").write_bytes(P.V.canonical(source))
        with self.assertRaisesRegex(ValueError, "source commit mismatch"):
            self.capture()
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
