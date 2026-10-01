#!/usr/bin/env python3
import copy
import importlib.util
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("native_capture", Path(__file__).with_name("capture-native-runtime-build.py"))
C = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C)
V = C.V
SOURCE_SPEC = importlib.util.spec_from_file_location("source_capture", Path(__file__).with_name("capture-runtime-source.py"))
SOURCE = importlib.util.module_from_spec(SOURCE_SPEC)
SOURCE_SPEC.loader.exec_module(SOURCE)


class NativeCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "LICENSE").write_text("MIT test source license\n")
        (self.source / "value.h").write_text("#define VALUE 7\n")
        (self.source / "helper.c").write_text('#include "value.h"\nint helper(void) { return VALUE; }\n')
        (self.source / "start.c").write_text("extern int helper(void); void _start(void) { volatile int x = helper(); for (;;) { (void)x; } }\n")
        environment = {**os.environ, "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                       "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.invalid"}
        def git(*args, input=None):
            return subprocess.check_output(["git", "-C", str(self.source), *args], env=environment, input=input)
        git("init", "--quiet")
        git("add", ".")
        tree = git("write-tree").decode().strip()
        commit = git("commit-tree", tree, input=b"test fixture\n").decode().strip()
        self.catalog = self.root / "catalog"
        project = SOURCE.capture(self.source, commit, self.catalog)
        data = (self.source / "LICENSE").read_bytes()
        (self.catalog / "LICENSE").write_bytes(data)
        license_record = dict(path="LICENSE", sha256=V.digest(data), sizeBytes=len(data),
                              sourcePath="LICENSE", component="native-test", spdx="MIT")
        project.update(identity="native-test", spdx="MIT", licenses=[license_record], notices=[license_record], patches=[])
        self.projects = {"native-test": V.source_project(project, lambda name: (self.catalog / name).read_bytes())}
        self.roots = {"native-test": self.source}
        self.evidence = self.root / "evidence"
        self.evidence.mkdir()

    def test_native_environment_retains_disabled_kernel_tool_selection(self):
        environment = C.process_environment({"PATH": "/usr/bin", "RUSTC": "/bin/false",
                                             "PAHOLE": "/dev/null",
                                             "MAKEFLAGS": "RUSTC=/bin/false PAHOLE=/dev/null",
                                             "RUSTUP_HOME": "/ambient/rust"})
        self.assertEqual(environment["RUSTC"], "/bin/false")
        self.assertEqual(environment["PAHOLE"], "/dev/null")
        self.assertEqual(environment["MAKEFLAGS"], "RUSTC=/bin/false PAHOLE=/dev/null")
        self.assertNotIn("RUSTUP_HOME", environment)

    def test_makefile_tool_assignments_cannot_override_kernel_disable_flags(self):
        make = shutil.which("make")
        if make is None or "GNU Make" not in subprocess.run(
                [make, "--version"], check=True, capture_output=True, text=True).stdout:
            self.skipTest("GNU Make is required")
        makefile = self.root / "Makefile"
        makefile.write_text("RUSTC = rustc\nPAHOLE = pahole\nquery:\n"
                            "\t@printf '%s\\n' '$(origin RUSTC)|$(RUSTC)|$(origin PAHOLE)|$(PAHOLE)'\n")
        environment = {**os.environ, "RUSTC": "ambient-rustc", "PAHOLE": "ambient-pahole",
                       "MAKEFLAGS": "RUSTC=/bin/false PAHOLE=/dev/null"}
        result = subprocess.run([make, "--no-print-directory", "-f", str(makefile), "query"],
                                cwd=self.root, env=environment, check=True, capture_output=True, text=True)
        self.assertEqual(result.stdout.strip(), "command line|/bin/false|command line|/dev/null")

    @unittest.skipUnless(platform.system() == "Linux" and shutil.which("strace") and shutil.which("gcc"),
                         "Linux strace and GCC are required")
    def test_kernel_capture_ignores_directory_symlinks_named_like_dependency_files(self):
        tree = self.root / "kernel-tree"
        dependency_directory = tree / "tools/testing/selftests/alsa"
        dependency_directory.mkdir(parents=True)
        (dependency_directory / "conf.d-real").mkdir()
        (dependency_directory / "conf.d-real" / "settings").write_text("test\n")
        (dependency_directory / "conf.d").symlink_to("conf.d-real", target_is_directory=True)
        (tree / ".config").write_text("CONFIG_ARM64=y\n")
        (tree / ".fixture.o.cmd").write_text(
            "savedcmd_fixture.o := " + shlex.quote(shutil.which("gcc")) + " --version\n")

        capture = C.retain_build(self.evidence, "kernel", tree)

        self.assertEqual([item["originalPath"] for item in capture["metadata"]],
                         [str(tree / ".fixture.o.cmd"), str(tree / ".config")])

    def test_compilation_database_reads_real_dependency_file_and_rejects_changed_source(self):
        obj = self.root / "helper.o"
        obj.write_bytes(b"object mapping test")
        dependency = self.root / "helper.d"
        dependency.write_text(str(obj) + ": " + str(self.source / "helper.c") + " \\\n " + str(self.source / "value.h") + "\n")
        database = self.root / "compile_commands.json"
        database.write_bytes(V.canonical([dict(directory=str(self.root), file=str(self.source / "helper.c"),
            arguments=["clang", "-c", str(self.source / "helper.c"), "-o", str(obj), "-MF", str(dependency)])]))
        rows = C.source_map_from_compile_commands(database, self.roots, self.projects)
        self.assertEqual({item["path"] for item in rows[0]["sourceFiles"]}, {"helper.c", "value.h"})
        (self.source / "value.h").write_text("#define VALUE 8\n")
        with self.assertRaisesRegex(ValueError, "differs from captured Git leaf"):
            C.source_map_from_compile_commands(database, self.roots, self.projects)

    def test_unmapped_generated_source_is_refused(self):
        generated = self.source / "generated.h"
        generated.write_text("#define GENERATED 1\n")
        with self.assertRaisesRegex(ValueError, "lacks a unique captured Git mapping"):
            C.source_file(generated, self.roots, self.projects)

    def test_swift_output_map_requires_source_list_for_module_object(self):
        obj = self.root / "module.o"
        obj.write_bytes(b"module output")
        mapping = self.root / "output-file-map.json"
        mapping.write_bytes(V.canonical({"": {"object": str(obj)}}))
        with self.assertRaisesRegex(ValueError, "actual source list"):
            C.source_map_from_swift_output_map(mapping, self.roots, self.projects)
        source_list = self.root / "sources"
        source_list.write_text(str(self.source / "helper.c") + "\n")
        rows = C.source_map_from_swift_output_map(mapping, self.roots, self.projects, source_list)
        self.assertEqual(rows[0]["sourceFiles"][0]["path"], "helper.c")

    def test_swift_file_object_uses_its_own_source_not_the_module_source_list(self):
        obj = self.root / "helper.o"
        obj.write_bytes(b"file output")
        mapping = self.root / "output-file-map.json"
        mapping.write_bytes(V.canonical({str(self.source / "helper.c"): {"object": str(obj)}}))
        source_list = self.root / "sources"
        source_list.write_text(str(self.source / "start.c") + "\n")
        rows = C.source_map_from_swift_output_map(mapping, self.roots, self.projects, source_list)
        self.assertEqual(rows[0]["sourceFiles"][0]["path"], "helper.c")

    def test_recursive_response_file_is_refused(self):
        response = self.root / "link.rsp"
        response.write_text("@" + str(response))
        with self.assertRaisesRegex(ValueError, "recursive native response"):
            C.response_files(["@" + str(response)], self.root)

    def test_successful_exec_trace_preserves_complete_argv_and_resumed_calls(self):
        trace = self.root / "exec.trace"
        trace.write_text('14 execve("/missing", ["/missing"], 0x0 /* 2 vars */) = -1 ENOENT (No such file)\n'
                         '15 execve("/usr/bin/clang", ["/usr/bin/clang", "a[1].c", "-DSTR=\\\"value\\\""], 0x0 /* 2 vars */) = 0\n'
                         '16 execve("/usr/bin/ld.lld", ["/usr/bin/ld.lld", "@inputs.rsp"], 0x0 <unfinished ...>\n'
                         '16 <... execve resumed>) = 0\n')
        values = C.successful_execs(trace)
        self.assertEqual([row["executablePath"] for row in values], ["/usr/bin/clang", "/usr/bin/ld.lld"])
        self.assertEqual(values[0]["argv"], ["/usr/bin/clang", "a[1].c", '-DSTR="value"'])

    @unittest.skipUnless(shutil.which("ninja") and shutil.which("clang"), "Ninja and clang are required")
    def test_consumed_depfile_falls_back_to_actual_ninja_dependency_database(self):
        arguments = [shutil.which("clang"), "-MMD", "-MF", "helper.d", "-c", str(self.source / "helper.c"), "-o", "helper.o"]
        (self.root / "build.ninja").write_text("rule compile\n  command = " + shlex.join(arguments) +
            "\n  depfile = helper.d\n  deps = gcc\nbuild helper.o: compile " + str(self.source / "helper.c") + "\n")
        subprocess.run([shutil.which("ninja"), "-C", str(self.root)], stdout=subprocess.PIPE, check=True)
        self.assertFalse((self.root / "helper.d").exists())
        database = self.root / "compile_commands.json"
        database.write_bytes(V.canonical([dict(directory=str(self.root), file=str(self.source / "helper.c"), arguments=arguments)]))
        values = C.source_map_from_compile_commands(database, self.roots, self.projects)
        self.assertEqual({row["path"] for row in values[0]["sourceFiles"]}, {"helper.c", "value.h"})

    @unittest.skipUnless(platform.system() == "Linux" and shutil.which("strace") and
                         shutil.which("clang") and shutil.which("ld.lld") and shutil.which("llvm-ar"),
                         "real ELF integration requires Linux clang, ld.lld, llvm-ar, and strace")
    def test_actual_static_arm64_link_closes_and_missing_sdk_mapping_fails(self):
        clang = shutil.which("clang")
        linker = shutil.which("ld.lld")
        commands = []
        for name in ("start", "helper"):
            obj = self.root / (name + ".o")
            depfile = self.root / (name + ".d")
            arguments = [clang, "--target=aarch64-linux-musl", "-ffreestanding", "-fno-stack-protector", "-MMD",
                         "-MF", str(depfile), "-c", str(self.source / (name + ".c")), "-o", str(obj)]
            subprocess.run(arguments, check=True)
            commands.append(dict(directory=str(self.root), file=str(self.source / (name + ".c")), arguments=arguments))
        database = self.root / "compile_commands.json"
        database.write_bytes(V.canonical(commands))
        source_map = C.source_map_from_compile_commands(database, self.roots, self.projects)
        (self.root / ".helper.o.cmd").write_text("savedcmd_helper.o := " + shlex.join(commands[1]["arguments"]) + "\n")
        (self.root / ".config").write_text("CONFIG_ARM64=y\n")
        kernel_capture = C.retain_build(self.evidence, "kernel", self.root)
        self.assertEqual(len(kernel_capture["invocations"]), 1)
        self.assertEqual(kernel_capture["unresolved"], [])
        self.assertEqual(V.parse((self.evidence / kernel_capture["invocations"][0]["argv"]["path"]).read_bytes()),
                         commands[1]["arguments"])
        archive = self.root / "libhelper.a"
        subprocess.run([shutil.which("llvm-ar"), "rcs", str(archive), str(self.root / "helper.o")], check=True)
        alias = self.root / "libalias.a"
        alias.symlink_to(archive.name)
        response = self.root / "link.rsp"
        response.write_text(str(self.root / "start.o") + "\n" + str(alias) + "\n")
        output = self.root / "program"
        map_file = self.root / "program.map"
        argv = [linker, "-static", "-e", "_start", "-Map=" + str(map_file), "-o", str(output), "@" + str(response)]
        invocation = C.run(self.evidence, "linker", argv)
        self.assertEqual(invocation["exitCode"], 0)
        compiler = C.record_tool(self.evidence, "compiler", clang)
        tools = V.toolchain(dict(toolchain=[compiler, invocation["toolchain"]]),
                            lambda name: (self.evidence / name).read_bytes())
        specification = dict(output=str(output), path="sbin/vminitd", map=str(map_file), cwd=str(self.root),
                             commands=[argv], responseFiles=[str(response)], sourceMap=source_map)
        link = C.collect_link(self.evidence, specification, self.projects, tools)
        self.assertTrue(any(row.get("member") == "helper.o" for row in link["selectedInputs"]))
        self.assertIn("libalias.a", {Path(row["file"]["path"]).name for row in link["selectedInputs"]})
        self.assertTrue(invocation["toolchain"]["loadedLibraries"])
        interpreter = C.executable_interpreter(linker)
        self.assertIsNotNone(interpreter)
        self.assertIn(Path(interpreter).name, {Path(row["path"]).name for row in invocation["toolchain"]["loadedLibraries"]})
        for tool in (compiler, invocation["toolchain"]):
            for library in tool["loadedLibraries"]:
                self.assertTrue((self.evidence / library["path"]).read_bytes().startswith(b"\x7fELF"))
        self.assertEqual((self.evidence / invocation["argv"]["path"]).read_bytes(), V.canonical(argv))
        trace = self.root / "link.exec.trace"
        subprocess.run([shutil.which("strace"), "-f", "-qq", "-yy", "-s", "65535", "-e", "trace=execve,mmap",
                        "-o", str(trace), "--", *argv], check=True)
        (self.root / ".build").mkdir()
        retained = C.retain_build(self.evidence, "swift", self.root, [trace], [map_file])
        self.assertEqual(retained["status"], "prepared-not-release-qualified")
        self.assertEqual(len(retained["invocations"]), 1)
        self.assertEqual(retained["unresolved"], [])
        self.assertEqual({row["objectSHA256"] for row in retained["links"][0]["selectedInputs"]},
                         {row["objectSHA256"] for row in link["selectedInputs"]})
        driver_response = self.root / "driver-response.txt"
        driver_response.write_text(shlex.join(argv[1:]) + "\n")
        invocation_directory = self.evidence / "linker-invocations"
        invocation_directory.mkdir()
        self.assertEqual(C.capture_linker(self.evidence, linker, ["@" + str(driver_response)], invocation_directory), 0)
        driver_response.unlink()
        response.unlink()
        wrapped = C.retain_build(self.evidence, "swift", self.root, [trace], [map_file], invocation_directory)
        actual = wrapped["invocations"][0]
        self.assertEqual(V.parse((self.evidence / actual["argv"]["path"]).read_bytes()),
                         [linker, "@" + str(driver_response)])
        wrapped_link = dict(link, commands=[actual["argv"]], workingDirectory=actual["cwd"],
                            responseFiles=[dict(row["file"], originalPath=row["originalPath"]) for row in actual["responseFiles"]])
        V.link_closure(wrapped_link, output.read_bytes(), self.projects,
                       lambda name: (self.evidence / name).read_bytes(), tools)
        # Restore the input used by the existing negative collection cases.
        response.write_text(str(self.root / "start.o") + "\n" + str(alias) + "\n")
        broken = copy.deepcopy(specification)
        broken["sourceMap"] = [source_map[0]]
        with self.assertRaisesRegex(ValueError, "missing or ambiguous compiled-source mapping"):
            C.collect_link(self.evidence, broken, self.projects, tools)
        broken = copy.deepcopy(specification)
        broken["sourceMap"][0]["sourceFiles"][0]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "selected source attribution mismatch"):
            C.collect_link(self.evidence, broken, self.projects, tools)


if __name__ == "__main__":
    unittest.main()
