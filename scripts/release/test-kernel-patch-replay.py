#!/usr/bin/env python3
"""Compare strict provenance replay with Git on the authenticated kernel source."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SPEC = importlib.util.spec_from_file_location("kernel_patch_verifier", HERE / "verify-runtime-provenance.py")
V = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(V)


class KernelPatchReplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        profile = json.loads((HERE / "kernel-security-candidate.json").read_text())
        archive_pin = next(row for row in profile["downloads"] if row["name"].endswith(".tar.xz"))
        with cls.source_archive.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != archive_pin["sha256"]:
                raise ValueError("kernel source archive differs from the reviewed pin")
        cls.patches = []
        paths = {"fs/coredump.c", "io_uring/waitid.c"}
        for row in profile["patches"]:
            data = (ROOT / row["path"]).read_bytes()
            if hashlib.sha256(data).hexdigest() != row["sha256"]:
                raise ValueError("kernel patch differs from the reviewed pin")
            cls.patches.append(data)
            paths.update(V.path(name.decode()) for name in re.findall(rb"^--- a/(.+)$", data, re.MULTILINE))
        cls.originals = {}
        prefix = "linux-" + profile["version"] + "/"
        with tarfile.open(cls.source_archive, "r|xz") as archive:
            for member in archive:
                if member.name.startswith(prefix) and member.name[len(prefix):] in paths:
                    name = member.name[len(prefix):]
                    if name in cls.originals or not member.isfile():
                        raise ValueError("ambiguous kernel patch source")
                    cls.originals[name] = archive.extractfile(member).read()
        if not paths or cls.originals.keys() != paths:
            raise ValueError("kernel source archive lacks patch targets")

    def patched_function(self, path, signature):
        sources = dict(self.originals)
        for patch in self.patches:
            V.apply_patch_bytes(patch, sources)
        return sources[path].decode().split(signature, 1)[1].split("\n}\n", 1)[0]

    def test_coredump_release_holds_rcu_across_task_clear_and_wakeup(self):
        body = self.patched_function("fs/coredump.c", "static void coredump_finish(bool core_dumped)")
        self.assertEqual(body.count("guard(rcu)();"), 1)
        operations = ["spin_unlock_irq(&current->sighand->siglock);", "guard(rcu)();",
                      "while ((curr = next) != NULL)", "task = curr->task;",
                      "curr->task = NULL;", "wake_up_process(task);"]
        positions = [body.index(operation) for operation in operations]
        self.assertEqual(positions, sorted(positions))

    def test_waitid_keeps_queue_head_until_callback_owns_request(self):
        body = self.patched_function("io_uring/waitid.c", "static int io_waitid_wait(")
        ownership = "if (atomic_fetch_inc(&iw->refs) & IO_WAITID_REF_MASK)\n\t\treturn 1;"
        self.assertEqual(body.count("smp_store_release(&iw->head, NULL);"), 1)
        operations = ["list_del_init(&wait->entry);", ownership,
                      "smp_store_release(&iw->head, NULL);", "req->io_task_work.func = io_waitid_cb;"]
        positions = [body.index(operation) for operation in operations]
        self.assertEqual(positions, sorted(positions))

    def test_strict_replay_matches_git_for_complete_patch_sequence(self):
        expected = dict(self.originals)
        with tempfile.TemporaryDirectory(prefix="kernel-patch-replay-") as temporary:
            tree = Path(temporary)
            for name, data in self.originals.items():
                path = tree / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            for patch in self.patches:
                V.apply_patch_bytes(patch, expected)
                subprocess.run(["git", "apply", "--check", "-"], input=patch, cwd=tree, check=True)
                subprocess.run(["git", "apply", "-"], input=patch, cwd=tree, check=True)
                for name, data in expected.items():
                    self.assertEqual((tree / name).read_bytes(), data, name)

    def test_offset_hunks_fail_strict_provenance_replay(self):
        expected = dict(self.originals)
        for patch in self.patches:
            bad = re.sub(rb"(?m)^@@ -(\d+)",
                         lambda match: b"@@ -" + str(int(match[1]) + 1).encode(), patch, count=1)
            with self.assertRaises(ValueError):
                V.apply_patch_bytes(bad, dict(expected))
            V.apply_patch_bytes(patch, expected)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-archive", type=Path, required=True)
    args = parser.parse_args()
    KernelPatchReplayTests.source_archive = args.source_archive
    unittest.main(argv=[__file__])
