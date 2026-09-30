#!/usr/bin/env python3
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location("sdk_objects", Path(__file__).with_name("capture-sdk-object-sources.py"))
C = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C)


@unittest.skipUnless(shutil.which("clang"), "real clang is required")
class ObjectSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.sources = self.root / "sources"
        self.project = self.sources / "example"
        self.project.mkdir(parents=True)
        self.build = self.root / "build"
        self.build.mkdir()
        self.sdk = self.root / "sdk"
        self.sdk.mkdir()
        (self.project / "value.h").write_text("#define VALUE 7\n")
        (self.project / "value.c").write_text('#include "value.h"\nint value(void) { return VALUE; }\n')
        (self.project / "generated.c").write_text('#include "generated.h"\nint generated(void) { return GENERATED; }\n')
        (self.project / "LICENSE").write_text("MIT fixture license\n")
        self.git("init", "--quiet")
        self.git("add", ".")
        tree = self.git("write-tree").decode().strip()
        commit = self.git("commit-tree", tree, input=b"Source mapping test\n").decode().strip()
        self.git("update-ref", "HEAD", commit)
        self.pins = [dict(destination="example", commit=commit)]
        self.arguments = [shutil.which("clang"), "--target=aarch64-linux-gnu", "-ffreestanding", "-MMD",
                          "-MF", "value.d", "-c", str(self.project / "value.c"), "-o", "value.o"]
        subprocess.run(self.arguments, cwd=self.build, check=True, capture_output=True)
        self.database(self.arguments, "value.c", "value.o")
        self.archive([self.build / "value.o"])

    def git(self, *arguments, input=None):
        return subprocess.check_output(["git", "-C", str(self.project), *arguments], input=input,
            env={**os.environ, "GIT_AUTHOR_NAME": "test", "GIT_COMMITTER_NAME": "test",
                 "GIT_AUTHOR_EMAIL": "test@example.invalid", "GIT_COMMITTER_EMAIL": "test@example.invalid"})

    def database(self, arguments, source, output):
        self.rows = [dict(directory=str(self.build), file=str(self.project / source), arguments=arguments, output=output)]
        (self.build / "compile_commands.json").write_bytes(C.V.canonical(self.rows))

    def archive(self, objects):
        data = bytearray(b"!<arch>\n")
        for obj in objects:
            raw = obj.read_bytes()
            data.extend(f'{obj.name + "/":<16}{0:<12}{0:<6}{0:<6}{0o644:<8o}{len(raw):<10}`\n'.encode())
            data.extend(raw)
            if len(raw) % 2:
                data.extend(b"\n")
        (self.sdk / "libexample.a").write_bytes(data)

    def capture(self, **kwargs):
        return C.capture(self.sources, [self.build], self.sdk, self.pins, **kwargs)

    def full_inputs(self, row):
        return C.V.parse(C.V.bound(row["compilerInputs"], lambda name: (self.root / C.V.path(name)).read_bytes()))

    def test_compact_representation_preserves_all_recorded_units_and_projects(self):
        other = self.sources / "other"
        subprocess.run(["git", "clone", "--quiet", str(self.project), str(other)], check=True)
        pins = self.pins + [dict(destination="other", commit=self.pins[0]["commit"])]
        sources = C.Sources(self.sources, pins, [])
        units = [sources.source(self.project / name) for name in ("value.c", "generated.c")]
        headers = [sources.source(path) for path in (self.project / "value.h", other / "value.h")]
        value = dict(objectSHA256=C.digest_file(self.build / "value.o"), sourceFiles=units + headers)
        retained = C.RetainedInputs(self.root / "compact", self.root)
        compact = C.compact_compiler_inputs(value, units, retained)
        self.assertEqual(len(compact["sourceFiles"]), 2)
        self.assertEqual({row["project"] for row in compact["sourceFiles"]},
                         {row["project"] for row in value["sourceFiles"]})
        self.assertIn(next(row for row in compact["sourceFiles"] if row["project"] == "swift-sdk/example"), units)
        full = self.full_inputs(compact)
        self.assertEqual(full["sourceFiles"], value["sourceFiles"])
        self.assertEqual({C.V.canonical(row) for row in full["translationUnits"]},
                         {C.V.canonical(row) for row in units})
        self.assertEqual(full["objectSHA256"], compact["objectSHA256"])
        self.assertEqual(Path(compact["compilerInputs"]["path"]).parent, Path("."))
        filename = self.root / compact["compilerInputs"]["path"]
        filename.write_bytes(filename.read_bytes() + b" ")
        with self.assertRaisesRegex(ValueError, "evidence bytes mismatch"):
            self.full_inputs(compact)
        with self.assertRaisesRegex(ValueError, "differs from its digest"):
            C.compact_compiler_inputs(value, units, retained)

    def test_identical_objects_with_same_translation_unit_are_attributed_to_that_unit(self):
        sources = C.Sources(self.sources, self.pins, [])
        unit = sources.source(self.project / "value.c")
        header = sources.source(self.project / "value.h")
        alternate = sources.source(self.project / "generated.c")
        retained = C.RetainedInputs(self.root / "mapping", self.root)
        digest = C.digest_file(self.build / "value.o")
        first = C.compact_compiler_inputs(dict(objectSHA256=digest, sourceFiles=[unit, header]), [unit], retained)
        second = C.compact_compiler_inputs(dict(objectSHA256=digest, sourceFiles=[unit, alternate]), [unit], retained)
        variants = {C.V.canonical(row): row for row in (first, second)}
        self.assertIn(digest, C.select_source_mappings({digest: variants}, retained))

        different = C.compact_compiler_inputs(dict(objectSHA256=digest, sourceFiles=[alternate]), [alternate], retained)
        variants[C.V.canonical(different)] = different
        selected = C.select_source_mappings({digest: variants}, retained)
        self.assertIn(digest, selected)
        combined = self.full_inputs(selected[digest])
        self.assertEqual({row["path"] for row in combined["translationUnits"]},
                         {"value.c", "generated.c"})
        self.assertEqual({row["path"] for row in combined["sourceFiles"]},
                         {"value.c", "generated.c", "value.h"})

        other = self.sources / "other"
        other.mkdir()
        (other / "other.c").write_text("int other(void) { return 7; }\n")
        other_env = {**os.environ, "GIT_AUTHOR_NAME": "test", "GIT_COMMITTER_NAME": "test",
                     "GIT_AUTHOR_EMAIL": "test@example.invalid", "GIT_COMMITTER_EMAIL": "test@example.invalid"}
        subprocess.run(["git", "-C", str(other), "init", "--quiet"], check=True)
        subprocess.run(["git", "-C", str(other), "add", "."], check=True)
        tree = subprocess.check_output(["git", "-C", str(other), "write-tree"]).decode().strip()
        commit = subprocess.check_output(["git", "-C", str(other), "commit-tree", tree],
                                         input=b"Other source project\n", env=other_env).decode().strip()
        subprocess.run(["git", "-C", str(other), "update-ref", "HEAD", commit], check=True)
        other_pins = self.pins + [dict(destination="other", commit=commit)]
        other_unit = C.Sources(self.sources, other_pins, []).source(other / "other.c")
        cross_project = C.compact_compiler_inputs(
            dict(objectSHA256=digest, sourceFiles=[other_unit]), [other_unit], retained)
        variants[C.V.canonical(cross_project)] = cross_project
        self.assertNotIn(digest, C.select_source_mappings({digest: variants}, retained))

    def test_compiler_input_records_reject_path_escape_and_symlink(self):
        self.compile_generated(self.build)
        result = self.capture(generated_output=self.root / "original")
        row = result["sourceMap"][0]
        full = self.full_inputs(row)
        record = full["generatedHeaders"][0]["file"]
        original_path = record["path"]
        record["path"] = "../outside.h"
        retained = C.RetainedInputs(self.root / "unsafe", self.root)
        with self.assertRaisesRegex(ValueError, "unsafe provenance path"):
            C.compact_compiler_inputs(full, full["translationUnits"], retained)
        record["path"] = original_path
        path = self.root / original_path
        path.unlink()
        path.symlink_to(self.build / "generated.h")
        with self.assertRaisesRegex(ValueError, "unsafe retained compiler input"):
            C.compact_compiler_inputs(full, full["translationUnits"], retained)
        with self.assertRaisesRegex(ValueError, "inside the mapping output directory"):
            C.RetainedInputs(self.root / ".." / "escaped", self.root)

    def test_real_compiler_dependencies_map_exact_installed_object_bytes(self):
        result = self.capture()
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        self.assertEqual(result["unresolved"], [])
        self.assertEqual({row["path"] for row in result["sourceMap"][0]["sourceFiles"]}, {"value.c", "value.h"})
        self.assertEqual(result["sourceMap"][0]["objectSHA256"], C.digest_file(self.build / "value.o"))
        self.assertEqual(result["status"], "partial-not-release-qualified")

    def test_nested_swift_output_file_map_resolves_object_from_build_root(self):
        (self.build / "compile_commands.json").unlink()
        directory = self.build / "target" / "CMakeFiles" / "example.dir" / "RelWithDebInfo"
        directory.mkdir(parents=True)
        mapping = directory / "output-file-map.json"
        mapping.write_bytes(C.V.canonical({str(self.project / "value.c"): {"object": "value.o"}}))
        result = self.capture()
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        self.assertEqual(result["sourceMap"][0]["objectSHA256"], C.digest_file(self.build / "value.o"))

    def test_installed_standalone_startup_object_is_selected_by_actual_bytes(self):
        (self.sdk / "libexample.a").unlink()
        startup = self.sdk / "crt1.o"
        shutil.copyfile(self.build / "value.o", startup)
        result = self.capture()
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        self.assertEqual(result["archiveMembers"], [dict(object=str(startup),
            objectSHA256=C.digest_file(startup), sizeBytes=startup.stat().st_size)])
        startup.write_bytes(startup.read_bytes() + b"unmapped bytes")
        result = self.capture()
        self.assertEqual(result["sourceMap"], [])
        self.assertEqual(result["unresolved"][0]["object"], str(startup))

    def test_zero_byte_clang_crt_placeholders_are_accounted_without_source_claims(self):
        placeholders = self.sdk / "aarch64" / "usr" / "lib" / "swift" / "clang" / "lib" / "linux"
        placeholders.mkdir(parents=True)
        for name in ("crtbeginT.o", "crtend.o"):
            (placeholders / name).write_bytes(b"")
        result = self.capture()
        self.assertEqual(result["unresolved"], [])
        self.assertEqual(result["counts"]["mappedMembers"], 3)
        self.assertEqual(result["counts"]["mappedObjects"], 1)
        self.assertEqual({row["disposition"] for row in result["emptyNonSourceMembers"]},
                         {"empty-clang-crt-placeholder"})
        self.assertTrue(all(row["sizeBytes"] == 0 and row["objectSHA256"] == C.V.digest(b"")
                            for row in result["emptyNonSourceMembers"]))

    def test_object_size_prefilter_still_requires_exact_digest_and_handles_unknown_sizes(self):
        obj = self.build / "value.o"
        original = obj.read_bytes()
        obj.write_bytes(bytes([original[0] ^ 1]) + original[1:])
        self.assertEqual(self.capture()["sourceMap"], [])
        obj.write_bytes(original + b"different size")
        with mock.patch.object(C, "digest_file", side_effect=AssertionError("different-size object must not be hashed")):
            self.assertEqual(self.capture()["sourceMap"], [])
        obj.write_bytes(original)
        result = C.capture(self.sources, [self.build], None, self.pins,
                           selected_inputs=[dict(objectSHA256=C.V.digest(original))])
        self.assertEqual(result["counts"]["mappedMembers"], 1)

    def test_generated_or_changed_dependencies_never_qualify(self):
        (self.project / "generated.h").write_text("#define GENERATED 4\n")
        arguments = self.arguments[:]
        arguments[arguments.index("value.d")] = "generated.d"
        arguments[arguments.index(str(self.project / "value.c"))] = str(self.project / "generated.c")
        arguments[arguments.index("value.o")] = "generated.o"
        subprocess.run(arguments, cwd=self.build, check=True, capture_output=True)
        self.database(arguments, "generated.c", "generated.o")
        self.archive([self.build / "generated.o"])
        result = self.capture()
        self.assertEqual(result["sourceMap"], [])
        self.assertEqual(len(result["unresolved"]), 1)
        self.assertIn("generated.h", result["rejectedInputs"][0]["reason"])
        (self.project / "value.h").write_text("#define VALUE 8\n")
        self.database(self.arguments, "value.c", "value.o")
        self.archive([self.build / "value.o"])
        self.assertEqual(self.capture()["sourceMap"], [])

    def test_relocated_original_build_and_source_paths_match(self):
        old = "/original"
        database = self.build / "compile_commands.json"
        database.write_text(database.read_text().replace(str(self.root), old))
        depfile = self.build / "value.d"
        depfile.write_text(depfile.read_text().replace(str(self.root), old))
        result = self.capture(relocations=[(Path(old), self.root)])
        self.assertEqual(result["counts"]["mappedMembers"], 1)

    def test_exact_retained_sdk_patch_binds_changed_source_bytes(self):
        source = self.project / "value.c"
        source.write_text('#include "value.h"\nint value(void) { return VALUE + 1; }\n')
        patch = subprocess.check_output(["git", "-C", str(self.project), "diff", "--binary", "--", "value.c"])
        patch_root = self.root / "sdk-build-inputs"
        (patch_root / "patches").mkdir(parents=True)
        patch_path = patch_root / "patches/example.patch"
        patch_path.write_bytes(patch)
        build_inputs = patch_root / "build-inputs.json"
        build_inputs.write_bytes(C.V.canonical({"sourceProjects": [dict(destination="example",
            source=dict(commit=self.pins[0]["commit"]), workingTreePatch=dict(
                path="patches/example.patch", sha256=C.V.digest(patch), sizeBytes=len(patch)))]}))
        subprocess.run(self.arguments, cwd=self.build, check=True, capture_output=True)
        self.database(self.arguments, "value.c", "value.o")
        self.archive([self.build / "value.o"])
        result = C.capture(self.sources, [self.build], self.sdk, self.pins,
                           sdk_build_inputs=build_inputs)
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        row = result["sourceMap"][0]["sourceFiles"]
        self.assertIn({"project": "swift-sdk/example", "path": "value.c", "sha256": C.V.digest(source.read_bytes())}, row)

    def test_timed_successful_trace_retains_sources_without_environment(self):
        (self.build / "compile_commands.json").unlink()
        trace = self.root / "build.trace"
        argv = json.dumps(self.arguments)
        environment = json.dumps(["PWD=" + str(self.build), "UNRELATED_SECRET=not-retained"])
        lines = [f'51 123.456 execve({json.dumps(self.arguments[0])}, {argv}, {environment}) <unfinished ...>',
                 '51 123.457 <... execve resumed>) = 0 <0.001>']
        for name in ("value.c", "value.h"):
            filename = str(self.project / name)
            lines.append(f'51 123.458 openat(AT_FDCWD, "{filename}", O_RDONLY) = 3<{filename}> <0.001>')
        lines.append('51 123.459 exit_group(0) = ?')
        trace.write_text("\n".join(lines) + "\n")
        result = self.capture(traces=[trace])
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        self.assertNotIn("UNRELATED_SECRET", C.V.canonical(result).decode())
        trace.write_text(trace.read_text().replace("exit_group(0)", "exit_group(1)"))
        self.assertEqual(self.capture(traces=[trace])["sourceMap"], [])

    def test_strace_unfinished_exit_group_resumed_as_success_maps_output(self):
        (self.build / "compile_commands.json").unlink()
        trace = self.root / "unfinished-exit.trace"
        argv = json.dumps(self.arguments)
        lines = [f'51 123.456 execve({json.dumps(self.arguments[0])}, {argv}, 0xffff /* 10 vars */) = 0 <0.001>']
        for name in ("value.c", "value.h"):
            filename = str(self.project / name)
            lines.append(f'51 123.457 openat(AT_FDCWD<{self.build}>, "{filename}", O_RDONLY <unfinished ...>')
            lines.append(f'51 123.458 <... openat resumed>) = 3<{filename}> <0.001>')
        lines.extend(['51 123.459 exit_group(0 <unfinished ...>',
                      '51 123.460 <... exit_group resumed>) = ?'])
        trace.write_text("\n".join(lines) + "\n")
        self.assertEqual(self.capture(traces=[trace], trace_cwd=self.build)["counts"]["mappedMembers"], 1)

    def test_swift_frontend_trace_maps_the_exact_swift_translation_unit(self):
        (self.build / "compile_commands.json").unlink()
        source = self.project / "value.swift"
        source.write_text("public func value() -> Int { 7 }\n")
        self.pin_current_files()
        copied_source = self.build / "value.swift"
        copied_source.write_bytes(source.read_bytes())
        output = self.build / "value.o"
        output.write_bytes(b"compiled Swift object fixture")
        self.archive([output])
        argv = ["swift-frontend", "-frontend", "-c", "-primary-file", str(source),
                "-emit-object", "-o", str(output)]
        trace = self.root / "swift-frontend.trace"
        trace.write_text("\n".join([
            f'51 123.456 execve("/toolchain/bin/swift-frontend", {json.dumps(argv)}, 0xffff /* 20 vars */) = 0 <0.001>',
            f'51 123.457 openat(AT_FDCWD<{self.build}>, "{source}", O_RDONLY) = 3<{source}> <0.001>',
            '51 123.458 exit_group(0) = ?',
        ]) + "\n")
        result = self.capture(traces=[trace], trace_cwd=self.build,
                              generated_output=self.root / "swift-generated")
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        row = self.full_inputs(result["sourceMap"][0])
        self.assertEqual([(item["project"], item["path"]) for item in row["translationUnits"]],
                         [("swift-sdk/example", "value.swift")])

    def test_swift_wmo_trace_retains_response_file_and_verifies_sources(self):
        (self.build / "compile_commands.json").unlink()
        source = self.project / "value.swift"
        source.write_text("public func value() -> Int { 7 }\n")
        self.pin_current_files()
        copied_source = self.build / "value.swift"
        copied_source.write_bytes(source.read_bytes())
        output = self.build / "value.o"
        output.write_bytes(b"compiled Swift WMO object fixture")
        self.archive([output])
        response = self.build / "sources.rsp"
        response.write_text(shlex.quote(str(copied_source)) + "\n")
        argv = ["swiftc", "-whole-module-optimization", "-o", str(output), "@sources.rsp"]
        trace = self.root / "swift-wmo.trace"
        trace.write_text("\n".join([
            f'51 123.456 execve("/toolchain/bin/swiftc", {json.dumps(argv)}, 0xffff /* 20 vars */) = 0 <0.001>',
            f'51 123.457 openat(AT_FDCWD<{self.build}>, "{copied_source}", O_RDONLY) = 3<{copied_source}> <0.001>',
            '51 123.458 exit_group(0) = ?',
        ]) + "\n")
        result = self.capture(traces=[trace], trace_cwd=self.build,
                              generated_output=self.root / "swift-wmo-retained")
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        record = result["sourceMap"][0]
        document = self.full_inputs(record)
        response_file = document["compilerResponseFiles"][0]
        self.assertEqual((self.root / response_file["file"]["path"]).read_bytes(), response.read_bytes())
        generated = document["generatedHeaders"][0]
        self.assertEqual(generated["kind"], "copied-source-input")
        self.assertEqual((self.root / generated["file"]["path"]).read_bytes(), source.read_bytes())
        verified = C.V.native_source_files(record, lambda name: (self.root / C.V.path(name)).read_bytes())
        self.assertEqual([(item["project"], item["path"]) for item in verified],
                         [("swift-sdk/example", "value.swift")])

    def test_relocated_swift_response_file_is_read_from_restored_build_root(self):
        (self.build / "compile_commands.json").unlink()
        source = self.project / "value.swift"
        source.write_text("public func value() -> Int { 7 }\n")
        self.pin_current_files()
        copied_source = self.build / "value.swift"
        copied_source.write_bytes(source.read_bytes())
        output = self.build / "value.o"
        output.write_bytes(b"compiled Swift WMO object fixture")
        self.archive([output])
        response = self.build / "sources.rsp"
        response.write_text(shlex.quote(str(copied_source)) + "\n")
        response_bytes = response.read_bytes()
        argv = ["swiftc", "-whole-module-optimization", "-o", str(output), "@" + str(response)]
        trace = self.root / "relocated-swift.trace"
        trace.write_text("\n".join([
            f'51 123.456 execve("/toolchain/bin/swiftc", {json.dumps(argv)}, 0xffff /* 20 vars */) = 0 <0.001>',
            f'51 123.457 openat(AT_FDCWD<{self.build}>, "{copied_source}", O_RDONLY) = 3<{copied_source}> <0.001>',
            '51 123.458 exit_group(0) = ?',
        ]) + "\n")

        relocated_build = self.root / "restored-build"
        self.build.rename(relocated_build)
        result = C.capture(self.sources, [relocated_build], self.sdk, self.pins,
            traces=[trace], relocations=[(self.build, relocated_build)], trace_cwd=self.build,
            generated_output=self.root / "relocated-retained",
            external_header_roots=[relocated_build])
        self.assertFalse(response.exists())
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        record = result["sourceMap"][0]
        document = C.V.parse(C.V.bound(record["compilerInputs"],
            lambda name: (self.root / C.V.path(name)).read_bytes()))
        response_record = document["compilerResponseFiles"][0]
        self.assertEqual((self.root / response_record["file"]["path"]).read_bytes(),
                         response_bytes)
        verified = C.V.native_source_files(record,
            lambda name: (self.root / C.V.path(name)).read_bytes())
        self.assertEqual([(item["project"], item["path"]) for item in verified],
                         [("swift-sdk/example", "value.swift")])

    def test_generated_swift_template_and_pcm_are_retained_and_verified(self):
        (self.build / "compile_commands.json").unlink()
        template = self.project / "Template.swift.gyb"
        template.write_text("public func generated() -> Int { 7 }\n")
        self.pin_current_files()
        generated = self.build / "generated.swift"
        generated.write_text(f'// ###sourceLocation(file: "{template}", line: 1)\n'
                             "public func generated() -> Int { 7 }\n"
                             f'// original-source-range: {template}:1:1\n')
        output = self.build / "generated.o"
        output.write_bytes(b"compiled generated Swift object fixture")
        module = self.build / "SwiftSupport.pcm"
        module.write_bytes(b"retained compiler module fixture")
        self.archive([output])
        response = self.build / "generated.rsp"
        response.write_text(shlex.quote(str(generated)) + "\n")
        argv = ["swift-frontend", "-frontend", "-c", "-filelist", str(response), "-o", str(output)]
        trace = self.root / "generated-swift.trace"
        trace.write_text("\n".join([
            f'51 123.456 execve("/toolchain/bin/swift-frontend", {json.dumps(argv)}, 0xffff /* 20 vars */) = 0 <0.001>',
            f'51 123.457 openat(AT_FDCWD<{self.build}>, "{generated}", O_RDONLY) = 3<{generated}> <0.001>',
            f'51 123.458 openat(AT_FDCWD<{self.build}>, "{module}", O_RDONLY) = 4<{module}> <0.001>',
            '51 123.459 exit_group(0) = ?',
        ]) + "\n")
        result = self.capture(traces=[trace], trace_cwd=self.build,
                              generated_output=self.root / "generated-swift-retained")
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        record = result["sourceMap"][0]
        document = self.full_inputs(record)
        generated_record = document["generatedHeaders"][0]
        self.assertEqual(generated_record["kind"], "generated-template-source-input")
        self.assertEqual((self.root / generated_record["file"]["path"]).read_bytes(), generated.read_bytes())
        module_record = document["compilerModuleFiles"][0]
        self.assertEqual((self.root / module_record["file"]["path"]).read_bytes(), module.read_bytes())
        response_record = document["compilerResponseFiles"][0]
        self.assertEqual((self.root / response_record["file"]["path"]).read_bytes(), response.read_bytes())
        self.assertEqual(C.V.native_source_files(record, lambda name: (self.root / C.V.path(name)).read_bytes())[0]["path"],
                         "Template.swift.gyb")

    def test_trace_without_environment_inherits_successful_working_directory(self):
        (self.build / "compile_commands.json").unlink()
        trace = self.root / "no-environment.trace"
        lines = ['50 123.100 chdir("build") = 0 <0.001>',
                 '50 123.101 chdir("missing") = -1 ENOENT (No such file or directory)',
                 '50 123.102 clone(child_stack=NULL, flags=SIGCHLD) = 51 <0.001>',
                 f'51 123.103 execve({json.dumps(self.arguments[0])}, {json.dumps(self.arguments)}, 0xffff /* 20 vars */) = 0 <0.001>']
        for name in ("value.c", "value.h"):
            filename = str(self.project / name)
            lines.append(f'51 123.104 openat(AT_FDCWD, "{filename}", O_RDONLY) = 3<{filename}> <0.001>')
        lines.append('51 123.105 exit_group(0) = ?')
        trace.write_text("\n".join(lines) + "\n")
        self.assertEqual(self.capture(traces=[trace], trace_cwd=self.root)["counts"]["mappedMembers"], 1)
        self.assertEqual(self.capture(traces=[trace])["sourceMap"], [])
        for change in [f'50 123.100 fchdir(3<{self.build}>) = 0 <0.001>',
                       '50 123.100 chdir("build") <unfinished ...>\n50 123.100 <... chdir resumed>) = 0 <0.001>']:
            trace.write_text("\n".join([change, *lines[1:]]) + "\n")
            self.assertEqual(self.capture(traces=[trace], trace_cwd=self.root)["counts"]["mappedMembers"], 1)

    def test_trace_descriptor_cwd_resolves_child_before_resumed_clone(self):
        (self.build / "compile_commands.json").unlink()
        trace = self.root / "descriptor-cwd.trace"
        lines = ['50 123.100 clone(child_stack=NULL, flags=SIGCHLD <unfinished ...>',
                 f'51 123.101 execve({json.dumps(self.arguments[0])}, {json.dumps(self.arguments)}, 0xffff /* 20 vars */) = 0 <0.001>',
                 '50 123.102 <... clone resumed>) = 51 <0.002>']
        for name in ("value.c", "value.h"):
            filename = str(self.project / name)
            lines.append(f'51 123.103 openat(AT_FDCWD<{self.build}>, "{filename}", O_RDONLY) = 3<{filename}> <0.001>')
        lines.append('51 123.104 exit_group(0) = ?')
        trace.write_text("\n".join(lines) + "\n")
        self.assertEqual(self.capture(traces=[trace])["counts"]["mappedMembers"], 1)

    @unittest.skipUnless(shutil.which("strace"), "real Linux strace is required")
    def test_real_strace_without_environment_maps_successful_compilation(self):
        (self.build / "compile_commands.json").unlink()
        trace = self.root / "real.trace"
        subprocess.run(["strace", "-f", "-qq", "-ttt", "-yy", "-s", "1048576", "-e", "trace=%process,%file",
                        "-o", str(trace), *self.arguments], cwd=self.build, check=True, capture_output=True)
        self.assertIn("vars */", trace.read_text())
        self.assertNotIn('"PWD=', trace.read_text())
        self.assertEqual(self.capture(traces=[trace], trace_cwd=self.build)["counts"]["mappedMembers"], 1)

    @unittest.skipUnless(shutil.which("strace"), "real Linux strace is required")
    def test_real_strace_child_process_attributes_assembly_translation_unit(self):
        (self.build / "compile_commands.json").unlink()
        source = self.project / "value.S"
        source.write_text(".text\n.globl value\n.type value,%function\nvalue:\n mov w0, #7\n ret\n")
        self.pin_current_files()
        output = self.build / "value.o"
        arguments = [shutil.which("clang"), "--target=aarch64-linux-gnu", "-c", str(source), "-o", str(output)]
        subprocess.run(arguments, cwd=self.build, check=True, capture_output=True)
        self.archive([output])
        trace = self.root / "assembly.trace"
        subprocess.run(["strace", "-f", "-qq", "-ttt", "-yy", "-s", "1048576", "-e",
                        "trace=%process,%file", "-o", str(trace), *arguments],
                       cwd=self.build, check=True, capture_output=True)
        result = self.capture(traces=[trace], trace_cwd=self.build,
                              generated_output=self.root / "assembly-retained")
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        units = self.full_inputs(result["sourceMap"][0])["translationUnits"]
        self.assertEqual([(row["project"], row["path"]) for row in units],
                         [("swift-sdk/example", "value.S")])

    def compile_generated(self, header_root):
        (header_root / "generated.h").write_text("#define GENERATED 4\n")
        arguments = self.arguments[:]
        arguments[arguments.index("value.d")] = "generated.d"
        arguments[arguments.index(str(self.project / "value.c"))] = str(self.project / "generated.c")
        arguments[arguments.index("value.o")] = "generated.o"
        arguments += ["-I", str(header_root)]
        subprocess.run(arguments, cwd=self.build, check=True, capture_output=True)
        self.database(arguments, "generated.c", "generated.o")
        self.archive([self.build / "generated.o"])
        return arguments

    def pin_current_files(self):
        self.git("add", ".")
        tree = self.git("write-tree").decode().strip()
        commit = self.git("commit-tree", tree, input=b"Copied header source fixture\n").decode().strip()
        self.git("update-ref", "HEAD", commit)
        self.pins[0]["commit"] = commit

    def test_same_project_copied_headers_retain_every_exact_source_match(self):
        self.compile_generated(self.build)
        for name in ("architecture-a.h", "architecture-b.h"):
            (self.project / name).write_bytes((self.build / "generated.h").read_bytes())
        self.pin_current_files()
        result = self.capture(generated_output=self.root / "copied-retained")
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        row = self.full_inputs(result["sourceMap"][0])
        self.assertEqual({item["path"] for item in row["sourceFiles"]},
                         {"generated.c", "architecture-a.h", "architecture-b.h"})
        header = row["generatedHeaders"][0]
        self.assertEqual(header["kind"], "copied-header")
        self.assertEqual({item["path"] for item in header["matchingSources"]},
                         {"architecture-a.h", "architecture-b.h"})
        self.assertEqual({item["sha256"] for item in header["matchingSources"]}, {header["file"]["sha256"]})
        (self.project / "architecture-a.h").write_text("#define GENERATED 100\n")
        dependencies = self.build / "generated.d"
        dependencies.write_text(dependencies.read_text().replace(str(self.build / "generated.h"),
                                                               str(self.project / "architecture-a.h")))
        result = self.capture(generated_output=self.root / "changed-copied-retained")
        self.assertEqual(result["sourceMap"], [])

    def test_copied_header_cross_project_matches_retain_all_candidates(self):
        self.compile_generated(self.build)
        (self.project / "shared.h").write_bytes((self.build / "generated.h").read_bytes())
        self.pin_current_files()
        other = self.sources / "other"
        subprocess.run(["git", "clone", "--quiet", str(self.project), str(other)], check=True)
        self.pins.append(dict(destination="other", commit=self.pins[0]["commit"]))
        result = self.capture(generated_output=self.root / "cross-project-retained")
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        row = self.full_inputs(result["sourceMap"][0])
        self.assertEqual({item["project"] for item in row["generatedHeaders"][0]["matchingSources"]},
                         {"swift-sdk/example", "swift-sdk/other"})

    def test_empty_copied_header_retains_zero_bytes_without_source_origin(self):
        arguments = self.compile_generated(self.build)
        (self.build / "generated.h").write_bytes(b"")
        (self.project / "unrelated-empty.h").write_bytes(b"")
        self.pin_current_files()
        other = self.sources / "other"
        subprocess.run(["git", "clone", "--quiet", str(self.project), str(other)], check=True)
        self.pins.append(dict(destination="other", commit=self.pins[0]["commit"]))
        arguments.append("-DGENERATED=4")
        subprocess.run(arguments, cwd=self.build, check=True, capture_output=True)
        self.database(arguments, "generated.c", "generated.o")
        self.archive([self.build / "generated.o"])
        result = self.capture(generated_output=self.root / "empty-retained")
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        row = self.full_inputs(result["sourceMap"][0])
        self.assertEqual([(item["project"], item["path"]) for item in row["sourceFiles"]],
                         [("swift-sdk/example", "generated.c")])
        header = row["generatedHeaders"][0]
        self.assertEqual(header["kind"], "empty-header")
        self.assertNotIn("matchingSources", header)
        self.assertEqual(header["file"]["sizeBytes"], 0)
        self.assertEqual(header["file"]["sha256"], C.V.digest(b""))
        self.assertEqual((self.root / header["file"]["path"]).read_bytes(), b"")
        self.assertEqual(header["compilerArguments"], arguments)
        self.assertEqual(len(header["retainedEvidence"]), 2)

    def test_cmake_generated_pch_source_is_retained_with_exact_bytes(self):
        pch_source = self.build / "cmake_pch.h.c"
        pch_source.write_bytes(b"/* generated by CMake */\n")
        sdk_settings = self.build / "SDKSettings.json"
        sdk_settings.write_text('{"Version": 1}\n')
        depfile = self.build / "value.d"
        depfile.write_text(depfile.read_text().rstrip() + " " + str(pch_source) + " " + str(sdk_settings) + "\n")
        result = self.capture(generated_output=self.root / "pch-retained")
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        generated = self.full_inputs(result["sourceMap"][0])["generatedHeaders"]
        by_kind = {row["kind"]: row for row in generated}
        for kind, original in (("generated-source-input", pch_source), ("sdk-configuration-input", sdk_settings)):
            self.assertIn(kind, by_kind)
            retained = self.root / by_kind[kind]["file"]["path"]
            self.assertEqual(retained.read_bytes(), original.read_bytes())
            self.assertEqual(by_kind[kind]["file"]["sha256"], C.V.digest(retained.read_bytes()))

    def test_explicit_external_header_root_is_retained_without_source_guessing(self):
        header = self.sdk / "target-header.h"
        header.write_text("#define TARGET_VALUE 7\n")
        depfile = self.build / "value.d"
        depfile.write_text(depfile.read_text().rstrip() + " " + str(header) + "\n")
        result = self.capture(generated_output=self.root / "target-header-retained",
                              external_header_roots=[self.sdk])
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        row = self.full_inputs(result["sourceMap"][0])["generatedHeaders"][0]
        self.assertEqual(row["originalPath"], str(header))
        retained = self.root / row["file"]["path"]
        self.assertEqual(retained.read_bytes(), header.read_bytes())

    def test_empty_translation_unit_cannot_qualify_a_compilation(self):
        (self.project / "value.c").write_bytes(b"")
        self.pin_current_files()
        subprocess.run(self.arguments, cwd=self.build, check=True, capture_output=True)
        self.archive([self.build / "value.o"])
        result = self.capture(generated_output=self.root / "empty-tu-retained")
        self.assertEqual(result["sourceMap"], [])
        self.assertIn("nonempty compiler translation unit", result["rejectedInputs"][0]["reason"])

    @unittest.skipUnless(shutil.which("strace"), "real Linux strace is required")
    def test_real_strace_binds_empty_translation_unit_to_exact_object(self):
        (self.build / "compile_commands.json").unlink()
        (self.project / "value.c").write_bytes(b"")
        self.pin_current_files()
        output = self.build / "value.o"
        trace = self.root / "empty-tu.trace"
        subprocess.run(["strace", "-f", "-qq", "-ttt", "-yy", "-s", "1048576", "-e",
                        "trace=%process,%file", "-o", str(trace), *self.arguments],
                       cwd=self.build, check=True, capture_output=True)
        self.archive([output])
        result = self.capture(traces=[trace], trace_cwd=self.build)
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        self.assertEqual(result["sourceMap"][0]["sourceFiles"], [dict(
            path="value.c", project="swift-sdk/example", sha256=C.V.digest(b""))])

    def test_extensionless_libcxx_header_requires_pinned_bytes_or_retained_build_input(self):
        arguments = self.compile_generated(self.build)
        (self.project / "generated.c").write_text('#include "__undef_macros"\nint generated(void) { return GENERATED; }\n')
        (self.build / "__undef_macros").write_bytes((self.build / "generated.h").read_bytes())
        self.pin_current_files()
        subprocess.run(arguments, cwd=self.build, check=True, capture_output=True)
        self.archive([self.build / "generated.o"])
        self.assertEqual(self.capture()["sourceMap"], [])
        result = self.capture(generated_output=self.root / "extensionless-retained")
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        header = self.full_inputs(result["sourceMap"][0])["generatedHeaders"][0]
        self.assertEqual(Path(header["originalPath"]).name, "__undef_macros")
        self.assertEqual((self.root / header["file"]["path"]).read_bytes(), (self.build / "__undef_macros").read_bytes())

    def test_copied_extensionless_header_requires_exact_pinned_source_bytes(self):
        sources = C.Sources(self.sources, self.pins, [])
        copied = self.sdk / "aarch64/usr/include/c++/v1/__config"
        copied.parent.mkdir(parents=True)
        pinned = (self.project / "value.h").read_bytes()
        copied.write_bytes(pinned)

        path, data, matches = sources.build_header(copied, None, [self.sdk.resolve()])
        self.assertEqual(path, copied.resolve())
        self.assertEqual(data, pinned)
        self.assertEqual([(row["project"], row["path"]) for row in matches],
                         [("swift-sdk/example", "value.h")])

        copied.write_bytes(pinned + b"/* changed */\n")
        with self.assertRaisesRegex(ValueError, "extensionless copied header lacks pinned source bytes"):
            sources.build_header(copied, None, [self.sdk.resolve()])

        copied.write_bytes(b"/* no pinned source proof */\n")
        with self.assertRaisesRegex(ValueError, "extensionless copied header lacks pinned source bytes"):
            sources.build_header(copied, None, [self.sdk.resolve()])

    def test_compiler_maps_copied_extensionless_header_to_pinned_source(self):
        include_root = self.sdk / "aarch64/usr/include/c++/v1"
        include_root.mkdir(parents=True)
        copied = include_root / "__config"
        copied.write_bytes((self.project / "value.h").read_bytes())
        (self.project / "generated.c").write_text(
            '#include "__config"\nint generated(void) { return VALUE; }\n')
        self.pin_current_files()
        arguments = self.arguments[:]
        arguments[arguments.index(str(self.project / "value.c"))] = str(self.project / "generated.c")
        arguments[arguments.index("value.o")] = "generated.o"
        arguments += ["-I", str(include_root)]
        subprocess.run(arguments, cwd=self.build, check=True, capture_output=True)
        self.database(arguments, "generated.c", "generated.o")
        self.archive([self.build / "generated.o"])

        result = self.capture(generated_output=self.root / "copied-extensionless-retained")
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        row = self.full_inputs(result["sourceMap"][0])
        header = next(item for item in row["generatedHeaders"] if item["originalPath"] == str(copied))
        self.assertEqual(header["kind"], "copied-header")
        self.assertEqual([(item["project"], item["path"]) for item in header["matchingSources"]],
                         [("swift-sdk/example", "value.h")])
        self.assertIn(("swift-sdk/example", "value.h"),
                      [(item["project"], item["path"]) for item in row["sourceFiles"]])

    def test_copied_extensionless_header_must_remain_inside_build_roots(self):
        copied = self.root / "outside" / "__config"
        copied.parent.mkdir()
        copied.write_bytes((self.project / "value.h").read_bytes())
        sources = C.Sources(self.sources, self.pins, [])
        with self.assertRaisesRegex(ValueError, "unverified external source"):
            sources.build_header(copied, None, [self.sdk.resolve()])

    def test_generated_build_header_retains_actual_bytes_and_compiler_evidence(self):
        arguments = self.compile_generated(self.build)
        result = self.capture(generated_output=self.root / "retained")
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        row = self.full_inputs(result["sourceMap"][0])
        self.assertEqual([source["path"] for source in row["sourceFiles"]], ["generated.c"])
        header = row["generatedHeaders"][0]
        self.assertEqual(header["compilerArguments"], arguments)
        self.assertEqual(header["cwd"], str(self.build))
        self.assertEqual((self.root / header["file"]["path"]).read_bytes(), (self.build / "generated.h").read_bytes())
        self.assertEqual(len(header["retainedEvidence"]), 2)
        for evidence in header["retainedEvidence"]:
            data = (self.root / evidence["file"]["path"]).read_bytes()
            self.assertEqual(data, Path(evidence["originalPath"]).read_bytes())
            self.assertEqual(C.V.digest(data), evidence["file"]["sha256"])

    def test_generated_trace_retention_omits_legacy_environment(self):
        arguments = self.compile_generated(self.build)
        (self.build / "compile_commands.json").unlink()
        trace = self.root / "generated.trace"
        environment = json.dumps(["PWD=" + str(self.build), "PRIVATE_BUILD_SECRET=do-not-copy"])
        lines = [f'51 123.100 execve({json.dumps(arguments[0])}, {json.dumps(arguments)}, {environment}) = 0 <0.001>']
        for filename in (self.project / "generated.c", self.build / "generated.h"):
            lines.append(f'51 123.101 openat(AT_FDCWD, "{filename}", O_RDONLY) = 3<{filename}> <0.001>')
        lines.append('51 123.102 exit_group(0) = ?')
        trace.write_text("\n".join(lines) + "\n")
        result = self.capture(traces=[trace], generated_output=self.root / "trace-retained")
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        evidence = self.full_inputs(result["sourceMap"][0])["generatedHeaders"][0]["retainedEvidence"][0]
        self.assertEqual(evidence["lineNumbers"], [2, 3, 4])
        self.assertEqual((self.root / evidence["file"]["path"]).read_text(), "\n".join(lines[1:]) + "\n")
        self.assertNotIn("PRIVATE_BUILD_SECRET", C.V.canonical(result).decode())
        self.assertNotIn("PRIVATE_BUILD_SECRET", C.V.canonical(self.full_inputs(result["sourceMap"][0])).decode())

    def test_generated_retention_rejects_external_headers_and_generated_translation_units(self):
        self.compile_generated(self.root)
        result = self.capture(generated_output=self.root / "external-retained")
        self.assertEqual(result["sourceMap"], [])
        self.assertIn("unverified external source", result["rejectedInputs"][0]["reason"])
        arguments = self.compile_generated(self.build)
        generated_source = self.build / "generated.c"
        generated_source.write_bytes((self.project / "generated.c").read_bytes().replace(b"return GENERATED", b"return GENERATED + 1"))
        arguments[arguments.index(str(self.project / "generated.c"))] = str(generated_source)
        subprocess.run(arguments, cwd=self.build, check=True, capture_output=True)
        self.database(arguments, str(generated_source), "generated.o")
        self.archive([self.build / "generated.o"])
        result = self.capture(generated_output=self.root / "tu-retained")
        self.assertEqual(result["sourceMap"], [])

    def test_generated_retention_never_accepts_changed_tracked_sources(self):
        (self.project / "value.h").write_text("#define VALUE 9\n")
        result = self.capture(generated_output=self.root / "changed-retained")
        self.assertEqual(result["sourceMap"], [])
        self.assertIn("unverified generated or changed source", result["rejectedInputs"][0]["reason"])

    def test_explicit_reviewed_patch_inventory_binds_changed_source(self):
        def load(name, filename):
            spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
        source = load("source_capture_test", "capture-runtime-source.py")
        prepare = load("source_prepare_test", "prepare-native-source-projects.py")
        inputs = self.root / "captured"
        inputs.mkdir()
        source.capture(self.project, self.pins[0]["commit"], inputs / "example")
        (self.project / "value.h").write_text("#define VALUE 9\n")
        (inputs / "change.patch").write_bytes(self.git("diff", "HEAD"))
        catalog = self.root / "catalog"
        prepare.prepare(inputs, [dict(identity="guest-example", sourceDirectory="example", spdx="MIT",
                                     licenses=["LICENSE"], notices=["LICENSE"], patches=["change.patch"])], catalog)
        subprocess.run(self.arguments, cwd=self.build, check=True, capture_output=True)
        self.archive([self.build / "value.o"])
        result = C.capture(self.sources, [self.build], self.sdk, [], projects_root=catalog,
                           source_roots={"guest-example": str(self.project)})
        self.assertEqual(result["counts"]["mappedMembers"], 1)
        self.assertEqual({row["project"] for row in result["sourceMap"][0]["sourceFiles"]}, {"guest-example"})
        (self.project / "value.h").write_text("#define VALUE 10\n")
        result = C.capture(self.sources, [self.build], self.sdk, [], projects_root=catalog,
                           source_roots={"guest-example": str(self.project)})
        self.assertEqual(result["sourceMap"], [])


if __name__ == "__main__":
    unittest.main()
