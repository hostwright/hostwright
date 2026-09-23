#!/usr/bin/env python3
import importlib.util
import os
import pathlib
import struct
import tarfile
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("runtime_rootfs", HERE / "create-runtime-rootfs.py")
ROOTFS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ROOTFS)


def executable(marker):
    data = bytearray(128)
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HH", data, 16, 2, 183)
    struct.pack_into("<Q", data, 32, 64)
    struct.pack_into("<HH", data, 54, 56, 1)
    struct.pack_into("<I", data, 64, 1)
    struct.pack_into("<QQ", data, 96, 128, 128)
    data[120:] = marker * 8
    return bytes(data)


class RuntimeRootfsTests(unittest.TestCase):
    def test_rootfs_is_independent_of_input_paths_and_timestamps(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            init = root / "vminitd"
            execute = root / "vmexec"
            init.write_bytes(executable(b"a"))
            execute.write_bytes(executable(b"b"))
            first = root / "first.tar.gz"
            ROOTFS.create(init, execute, first)
            init.rename(root / "renamed")
            init = root / "renamed"
            os.utime(init, (1900000000, 1900000000))
            os.utime(execute, (1800000000, 1800000000))
            second = root / "second.tar.gz"
            ROOTFS.create(init, execute, second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with tarfile.open(first, "r:gz") as archive:
                self.assertEqual(archive.extractfile("sbin/vminitd").read(), init.read_bytes())
                self.assertEqual(archive.extractfile("sbin/vmexec").read(), execute.read_bytes())
                self.assertEqual(archive.getmember("proc/self/exe").linkname, "sbin/vminitd")
                self.assertEqual([m.name for m in archive.getmembers() if m.isfile()],
                                 ["sbin/vminitd", "sbin/vmexec"])
                self.assertTrue(all(m.mtime == 0 and m.uid == 0 and m.gid == 0
                                    and m.mode == 0o755 for m in archive.getmembers()))

    def test_invalid_executable_and_symlink_do_not_create_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source = root / "input"
            source.write_bytes(b"not an executable")
            output = root / "out.tar.gz"
            with self.assertRaises(ValueError):
                ROOTFS.create(source, source, output)
            self.assertFalse(output.exists())
            source.write_bytes(executable(b"a"))
            alias = root / "alias"
            alias.symlink_to(source)
            with self.assertRaises(ValueError):
                ROOTFS.create(alias, source, output)
            self.assertFalse(output.exists())

    def test_existing_output_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source = root / "input"
            source.write_bytes(executable(b"a"))
            output = root / "out.tar.gz"
            output.write_bytes(b"retained evidence")
            with self.assertRaises(ValueError):
                ROOTFS.create(source, source, output)
            self.assertEqual(output.read_bytes(), b"retained evidence")


if __name__ == "__main__":
    unittest.main()
