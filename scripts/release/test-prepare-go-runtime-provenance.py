#!/usr/bin/env python3
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CAPTURE = load("go_build_capture", "capture-go-build.py")
PREPARE = load("go_provenance_prepare", "prepare-go-runtime-provenance.py")


@unittest.skipUnless(sys.platform == "linux" and shutil.which("strace"),
                     "actual Go toolchain evidence requires Linux strace")
class GoToolchainPreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        source = cls.root / "source"
        source.mkdir()
        (source / "go.mod").write_text("module example.test/toolchain\n\ngo 1.21\n")
        (source / "go.sum").write_text("")
        (source / "main.go").write_text('package main\nfunc main() { println("toolchain") }\n')
        executable = os.environ.get("GO_CAPTURE_TEST_GO") or shutil.which("go")
        if not executable:
            raise RuntimeError("the real Go toolchain is required")
        cls.capture_root = cls.root / "capture"
        cls.capture = CAPTURE.build(Path(executable), source, cls.capture_root, 1)
        cls.commands = [json.loads(PREPARE.V.bound(item, cls.fetch)) for item in cls.capture["commands"]]

    @classmethod
    def fetch(cls, name):
        return (cls.capture_root / name).read_bytes()

    def setUp(self):
        self.output = self.root / self._testMethodName
        self.output.mkdir()

    def read_record(self, record):
        data = (self.output / record["path"]).read_bytes()
        self.assertEqual(record["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(record["sizeBytes"], len(data))
        return data

    def test_actual_build_registers_every_executable_with_bound_evidence(self):
        tools = PREPARE.capture_toolchain(self.output, self.capture,
                                         self.commands + [copy.deepcopy(self.commands[0])], self.fetch)
        expected = {item["argv"][0]: item["executable"]["sha256"] for item in self.commands}
        expected[self.capture["command"][0]] = self.capture["executable"]["sha256"]
        wrapper = self.capture["toolExec"]
        expected[wrapper["interpreterPath"]] = wrapper["interpreter"]["sha256"]
        expected.update({item["headerTrace"]["argv"][0]: item["headerTrace"]["executable"]["sha256"]
                         for item in self.commands if "headerTrace" in item})
        self.assertEqual(len(tools), len(expected))
        self.assertEqual({item["executablePath"]: item["executable"]["sha256"] for item in tools}, expected)
        self.assertEqual(len({item["identity"] for item in tools}), len(tools))
        self.assertTrue({"go-driver", "go-collector-python", "go-header-tracer", "go-compile", "go-asm", "go-link"}
                        <= {item["identity"] for item in tools})
        for tool in tools:
            self.assertTrue(self.read_record(tool["executable"]).startswith(b"\x7fELF"))
            self.assertTrue(self.read_record(tool["version"]).strip())
            environment = json.loads(self.read_record(tool["environment"]))
            self.assertEqual(environment["GOOS"], "linux")
            self.assertEqual(environment["GOARCH"], "arm64")
            command = json.loads(self.read_record(tool["versionCommand"]))
            self.assertEqual(command[0], tool["executablePath"])
            self.assertTrue(self.read_record(tool["libraryTrace"]))
            for library in tool["loadedLibraries"]:
                self.assertTrue(self.read_record(library).startswith(b"\x7fELF"), library["path"])
            if tool["identity"] in {"go-collector-python", "go-header-tracer"}:
                self.assertTrue(tool["loadedLibraries"])

    def test_refuses_executable_digest_that_differs_from_actual_tool(self):
        capture = copy.deepcopy(self.capture)
        capture["executable"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "Go tool changed after the captured build"):
            PREPARE.capture_toolchain(self.output, capture, self.commands, self.fetch)

    def test_refuses_conflicting_executable_bytes_before_capturing_tools(self):
        conflict = copy.deepcopy(self.commands[0])
        conflict["executable"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "conflicting executable bytes"):
            PREPARE.capture_toolchain(self.output, self.capture, self.commands + [conflict], self.fetch)
        self.assertEqual(list(self.output.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
