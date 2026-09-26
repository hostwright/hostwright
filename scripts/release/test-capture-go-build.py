#!/usr/bin/env python3
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("capture_go_build", Path(__file__).with_name("capture-go-build.py"))
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)
VERIFIER_SPEC = importlib.util.spec_from_file_location("runtime_verifier", Path(__file__).with_name("verify-runtime-provenance.py"))
VERIFIER = importlib.util.module_from_spec(VERIFIER_SPEC)
VERIFIER_SPEC.loader.exec_module(VERIFIER)


class GoBuildCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "go.mod").write_text("module example.test/capture\n\ngo 1.21\n")
        (self.source / "go.sum").write_text("")
        (self.source / "main.go").write_text('package main\nfunc main() { println("capture") }\n')
        executable = os.environ.get("GO_CAPTURE_TEST_GO") or shutil.which("go")
        self.assertIsNotNone(executable, "the real Go toolchain is required")
        self.go = Path(executable)

    def read_record(self, root, record):
        data = (root / record["path"]).read_bytes()
        self.assertEqual(record["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(record["sizeBytes"], len(data))
        return data

    @unittest.skipUnless(sys.platform == "linux" and shutil.which("strace"), "actual header capture requires Linux strace")
    def test_actual_build_retains_linked_archives_and_preserves_payload(self):
        output = self.root / "capture"
        metadata = CAPTURE.build(self.go, self.source, output, 1)
        commands = [json.loads(self.read_record(output, item)) for item in metadata["commands"]]
        self.assertEqual(len(commands), len(list((output / "commands").glob("*.json"))))
        for command in commands:
            self.assertEqual(command["exitCode"], 0)
            self.read_record(output, command["executable"])
            for item in command["inputs"] + command["includeCandidates"] + command["openedHeaders"] + command["packageArchives"] + command.get("outputs", []):
                self.read_record(output, item["file"])
        link = next(command for command in commands if Path(command["argv"][0]).name == "link"
                    and "-importcfg" in command["argv"])
        self.assertTrue(link["packageArchives"])
        for package in link["packageArchives"]:
            archive = self.read_record(output, package["file"])
            self.assertTrue(archive.startswith(b"!<arch>\n"))
            self.assertIn(b"__.PKGDEF", archive)
            self.assertIn("__.PKGDEF", VERIFIER.archive_members(archive, padding=b"\0"))
        main = next(command for command in commands if command["package"] == "example.test/capture"
                    and Path(command["argv"][0]).name == "compile" and "-o" in command["argv"])
        self.assertIn(str((self.source / "main.go").resolve()), [item["originalPath"] for item in main["inputs"]])
        environment = json.loads(self.read_record(output, metadata["environment"]))
        self.assertEqual(environment["GOENV"], "off")
        self.assertEqual(environment["GOWORK"], "off")
        self.assertEqual(environment["GOFLAGS"], "")
        packages = json.loads(self.read_record(output, metadata["packages"]))
        main_package = next(package for package in packages if package["ImportPath"] == "example.test/capture")
        self.assertEqual([item["originalPath"] for item in main_package["retainedSources"]],
                         [str((self.source / "main.go").resolve())])
        ordinary = self.root / "ordinary"
        subprocess.run([str(self.go), "build", "-p=1", "-mod=readonly", "-trimpath", "-buildvcs=false",
                        "-gcflags=all=-buildid=", "-ldflags=-buildid= -s -w", "-o", str(ordinary), "."],
                       cwd=self.source, env=environment, check=True, capture_output=True)
        self.assertEqual(self.read_record(output, metadata["payload"]), ordinary.read_bytes())
        version, modules = VERIFIER.go_build_info(ordinary.read_bytes())
        self.assertTrue(version.startswith("go1."))
        self.assertEqual(modules, [["example.test/capture", "(devel)"]])
        tools = {item["argv"][0]: item["executable"]["sha256"] for item in commands}
        tools[metadata["command"][0]] = metadata["executable"]["sha256"]
        tools[metadata["toolExec"]["interpreterPath"]] = metadata["toolExec"]["interpreter"]["sha256"]
        tools.update({item["headerTrace"]["argv"][0]: item["headerTrace"]["executable"]["sha256"]
                      for item in commands if "headerTrace" in item})

        def verify(changed=None):
            retained = {}
            capture = copy.deepcopy(metadata)
            selected = copy.deepcopy(commands)
            if changed:
                changed(selected)
            capture["commands"] = []
            for index, command in enumerate(selected):
                name = "changed-command-" + str(index)
                data = CAPTURE.canonical(command)
                retained[name] = data
                capture["commands"].append(dict(path=name, sha256=VERIFIER.digest(data), sizeBytes=len(data)))
            data = CAPTURE.canonical(capture)
            retained["build.json"] = data
            return VERIFIER.go_capture(dict(path="build.json", sha256=VERIFIER.digest(data), sizeBytes=len(data)),
                ordinary.read_bytes(), lambda name: retained[name] if name in retained else (output / name).read_bytes(), tools)

        packages, _ = verify()
        self.assertIn("example.test/capture", packages)
        retained = {}
        def add(name, data):
            retained[name] = data
            return dict(path=name, sha256=VERIFIER.digest(data), sizeBytes=len(data))
        projects = {"main": {}, "runtime": {}}
        collector_source = dict(sha256=metadata["collector"]["sha256"], sizeBytes=metadata["collector"]["sizeBytes"], gitMode="100644")
        projects["main"]["scripts/release/capture-go-build.py"] = collector_source
        trace = []
        for name, package in packages.items():
            source_records = []
            for filename, digest in sorted(package["sources"]):
                project = "main" if Path(filename).is_relative_to(self.source.resolve()) else "runtime"
                relative = filename.removeprefix("/")
                projects[project][relative] = dict(sha256=digest)
                source_records.append(dict(project=project, path=relative, originalPath=filename, sha256=digest))
            trace.append(dict(package=name, project="main" if name=="example.test/capture" else "runtime",
                              archive=package["archive"], sourceFiles=source_records))
        sources = {CAPTURE.canonical(item): item for package in trace for item in package["sourceFiles"]}
        loader = dict(format="go-buildinfo-v1", path="payload", outputSHA256=VERIFIER.digest(ordinary.read_bytes()),
                      project="main", goRuntimeProject="runtime", goVersion=version,
                      modules=[dict(project="main", revision="a"*40, buildInfo=modules[0])], moduleRevisions={"main":"a"*40},
                      sourceFiles=list(sources.values()), compiler=main["executable"],
                      commands=[add("argv-"+str(index), CAPTURE.canonical(item["argv"])) for index,item in enumerate(commands)],
                      buildCapture=add("build.json", CAPTURE.canonical(metadata)),
                      packageTrace=add("package-trace.json", CAPTURE.canonical(trace)))
        def verify_loader():
            VERIFIER.go_loader(loader, ordinary.read_bytes(), projects,
                lambda name: retained[name] if name in retained else (output / name).read_bytes(), tools)
        verify_loader()
        collector_source["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "collector does not match"):
            verify_loader()
        collector_source["sha256"] = metadata["collector"]["sha256"]
        for field in ("archive", "sourceFiles"):
            changed = copy.deepcopy(trace)
            if field=="archive":
                changed[0]["archive"] = changed[-1]["archive"]
            else:
                changed[0]["sourceFiles"][0]["originalPath"] += ".stale"
            loader["packageTrace"] = add("package-trace.json", CAPTURE.canonical(changed))
            with self.subTest(trace=field), self.assertRaisesRegex(ValueError, "differs from actual build"):
                verify_loader()
        loader["packageTrace"] = add("package-trace.json", CAPTURE.canonical(trace))
        loader["sourceFiles"].pop()
        with self.assertRaisesRegex(ValueError, "source inventory differs"):
            verify_loader()
        def tool_command(rows, name):
            return next(item for item in rows if Path(item["argv"][0]).name == name and "-o" in item["argv"])
        def omit_source(rows):
            command = tool_command(rows, "compile")
            command["inputs"] = [item for item in command["inputs"] if not item["originalPath"].endswith(".go")]
        def invent_source(rows):
            command = tool_command(rows, "compile")
            source = copy.deepcopy(next(item for item in command["inputs"] if item["originalPath"].endswith(".go")))
            source["originalPath"] += ".extra.go"
            command["inputs"].append(source)
        def substitute_archive(rows):
            command = tool_command(rows, "link")
            command["packageArchives"][0]["file"] = command["packageArchives"][-1]["file"]
        def omit_header(rows):
            command = next(item for item in rows if item["openedHeaders"])
            command["openedHeaders"].pop()
        def omit_assembler(rows):
            command = next(item for item in rows if Path(item["argv"][0]).name == "asm"
                           and "-o" in item["argv"] and "-gensymabis" not in item["argv"])
            rows.remove(command)
        def change_link_output(rows):
            tool_command(rows, "link")["outputs"][0]["file"] = metadata["collector"]
        def change_trace_path(rows):
            command = next(item for item in rows if item["openedHeaders"])
            command["headerTrace"]["originalPath"] += ".stale"
        def change_experiment(rows):
            tool_command(rows, "compile")["environment"]["GOEXPERIMENT"] = "loopvar"
        for change in (omit_source, invent_source, substitute_archive, omit_header, omit_assembler, change_link_output, change_trace_path, change_experiment):
            with self.subTest(change=change.__name__), self.assertRaises(ValueError):
                verify(change)

    def test_refuses_existing_or_linked_output_without_modification(self):
        existing = self.root / "existing"
        existing.mkdir()
        (existing / "personal").write_text("retain")
        link = self.root / "link"
        link.symlink_to(existing, target_is_directory=True)
        for output in [existing, link]:
            with self.assertRaisesRegex(ValueError, "new absolute output"):
                CAPTURE.build(self.go, self.source, output, 1)
        self.assertEqual((existing / "personal").read_text(), "retain")

    def test_refuses_unlocked_module(self):
        (self.source / "go.sum").unlink()
        with self.assertRaisesRegex(ValueError, "locked Go module"):
            CAPTURE.build(self.go, self.source, self.root / "capture", 1)
        self.assertFalse((self.root / "capture").exists())

    def test_refuses_changed_distribution_before_reading_sources(self):
        archive = self.root / "distribution.tar.gz"
        archive.write_bytes(b"changed distribution")
        with self.assertRaisesRegex(ValueError, "archive digest mismatch"):
            CAPTURE.prepare(self.root / "unread-source", "a" * 40, archive, "0" * 64,
                            self.root / "prepared")
        self.assertFalse((self.root / "prepared").exists())


if __name__ == "__main__":
    unittest.main()
