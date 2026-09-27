#!/usr/bin/env python3
import importlib.util
import hashlib
import json
import shlex
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("native_source_map", HERE / "capture-native-source-map.py")
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class NativeSourceMapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.tree = self.root / "containerization-build" / "vminitd"
        self.captures = self.root / "captures"
        self.sdk_root = self.root / "sdk-map"
        self.tree.mkdir(parents=True)
        self.captures.mkdir()
        self.sdk_root.mkdir()
        self.output = self.root / "combined-source-map.json"

        sources_root = self.captures / "containerization"
        sources_root.mkdir()
        for directory in ("linux",):
            (self.captures / directory).mkdir()
        package_root = self.captures / "vminit-packages"
        package_root.mkdir()
        (package_root / "sample").mkdir()
        self.write_source(package_root, "sources.json", [dict(identity="sample", directory="sample")])

        source_root = self.tree / "Sources"
        source_root.mkdir(parents=True)
        source_file = source_root / "Main.swift"
        source_file.write_text("print(\"runtime\")\n")
        self.write_source(sources_root, "source-inventory.json", [dict(
            path="vminitd/Sources/Main.swift", gitMode="100644")])
        package_file = self.tree / ".build" / "checkouts" / "sample" / "Sources" / "Sample.swift"
        package_file.parent.mkdir(parents=True)
        package_file.write_text("public struct Sample {}\n")
        self.write_source(package_root / "sample", "source-inventory.json", [dict(
            path="Sources/Sample.swift", gitMode="100644")])
        object_file = self.tree / ".build" / "main.o"
        object_file.parent.mkdir(parents=True, exist_ok=True)
        object_file.write_bytes(b"local-object")
        output_map = object_file.parent / "output-file-map.json"
        self.write_source(output_map.parent, output_map.name,
                          {"Sources/Main.swift": {"object": "main.o"}})
        self.write_source(output_map.parent, "sources", "Sources/Main.swift\n")


        sdk_source_evidence = self.sdk_root / "compiler-inputs.json"
        self.sdk_source = dict(project="sdk-project", path="source.c", sha256="b" * 64)
        self.sdk_header = dict(project="sdk-project", path="include/copied.h", sha256="c" * 64)
        sdk_document = dict(objectSHA256="a" * 64,
                            sourceFiles=[self.sdk_source, self.sdk_header],
                            translationUnits=[self.sdk_source])
        sdk_source_evidence.write_bytes(M.V.canonical(sdk_document))
        self.sdk_object = dict(objectSHA256="a" * 64,
            sourceFiles=[self.sdk_source],
            compilerInputs=dict(path="compiler-inputs.json", sha256=M.V.digest(sdk_source_evidence.read_bytes()),
                                sizeBytes=sdk_source_evidence.stat().st_size))
        self.write_source(self.sdk_root, "sdk-object-sources.json", {
            "kind": "hostwright.sdk-object-sources.v1", "status": "partial-not-release-qualified",
            "sourceMap": [self.sdk_object], "unresolved": []})
        self.sdk_map = self.sdk_root / "sdk-object-sources.json"
        self.native_capture = self.root / "native-swift.json"
        self.write_source(self.root, self.native_capture.name, {
            "kind": "swift", "status": "prepared-not-release-qualified",
            "links": [{"selectedInputs": [
                dict(mapInput="libSDK.a(member.o)", objectSHA256="a" * 64),
                dict(mapInput=str(object_file), objectSHA256=M.V.digest(object_file.read_bytes()))]}]})

    @staticmethod
    def sha(data):
        return hashlib.sha256(data).hexdigest()

    def add_c_invocation(self, dependency_contents, *, retain_depfile=True, stem="native"):
        source = self.tree / "Sources" / (stem + ".c")
        source.write_text("int runtime(void) { return 1; }\n")
        inventory = self.captures / "containerization" / "source-inventory.json"
        entries = json.loads(inventory.read_text())
        entries.append(dict(path="vminitd/Sources/" + stem + ".c", gitMode="100644"))
        inventory.write_text(json.dumps(entries))

        copied_header = self.tree / "include" / "copied.h"
        copied_header.parent.mkdir(parents=True, exist_ok=True)
        copied_header.write_bytes(b"/* retained SDK header */\n")
        self.sdk_header["sha256"] = self.sha(copied_header.read_bytes())
        sdk_evidence = self.sdk_root / "compiler-inputs.json"
        sdk_document = json.loads(sdk_evidence.read_text())
        sdk_document["sourceFiles"][1]["sha256"] = self.sdk_header["sha256"]
        sdk_evidence.write_bytes(M.V.canonical(sdk_document))
        self.sdk_object["compilerInputs"] = dict(path="compiler-inputs.json",
            sha256=self.sha(sdk_evidence.read_bytes()), sizeBytes=sdk_evidence.stat().st_size)
        sdk_capture = json.loads(self.sdk_map.read_text())
        sdk_capture["sourceMap"][0] = self.sdk_object
        self.sdk_map.write_text(json.dumps(sdk_capture))

        object_file = self.tree / ".build" / (stem + ".o")
        object_file.write_bytes((stem + "-c-object").encode())
        depfile = self.tree / ".build" / (stem + ".d")
        depfile.write_text(dependency_contents)
        argv = ["clang", "-c", "Sources/" + stem + ".c", "-MF", ".build/" + stem + ".d",
                "-o", ".build/" + stem + ".o"]
        argv_file = self.root / (stem + "-argv.json")
        argv_file.write_bytes(M.V.canonical(argv))
        record = dict(path=argv_file.name, sha256=self.sha(argv_file.read_bytes()),
                      sizeBytes=argv_file.stat().st_size)
        native = json.loads(self.native_capture.read_text())
        native.setdefault("invocations", []).append(
            dict(executablePath="/usr/bin/clang", argv=record, responseFiles=[]))
        native["links"][0]["selectedInputs"].append(
            dict(mapInput=str(object_file), objectSHA256=self.sha(object_file.read_bytes())))
        if retain_depfile:
            retained_depfile = self.root / (stem + "-depfile.d")
            retained_depfile.write_text(dependency_contents)
            native.setdefault("metadata", []).append(dict(originalPath=str(depfile.resolve()), file=dict(
                path=retained_depfile.name, sha256=self.sha(retained_depfile.read_bytes()),
                sizeBytes=retained_depfile.stat().st_size)))
        else:
            native["metadata"] = []
        self.native_capture.write_text(json.dumps(native))
        return object_file, argv_file

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def write_source(directory, name, value):
        target = directory / name
        if isinstance(value, (dict, list)):
            target.write_text(json.dumps(value))
        else:
            target.write_text(value)

    def test_joins_live_swift_objects_and_only_selected_sdk_members(self):
        rows = M.capture(self.tree, self.captures, self.sdk_map, self.sdk_root,
                         self.native_capture, self.output)
        self.assertEqual({row.get("mapInput") for row in rows}, {None, "libSDK.a(member.o)"})
        self.assertEqual((self.root / "source-map" / "compiler-inputs.json").read_bytes(),
                         (self.sdk_root / "compiler-inputs.json").read_bytes())
        self.assertEqual(json.loads(self.output.read_text()), rows)

    def test_compiler_scheduling_does_not_change_complete_source_map_bytes(self):
        self.add_c_invocation(".build/native.o: Sources/native.c include/copied.h\n")
        self.add_c_invocation(".build/other.o: Sources/other.c include/copied.h\n", stem="other")
        first = self.root / "first" / "source-map.json"
        second = self.root / "second" / "source-map.json"
        for output in (first, second):
            output.parent.mkdir()
        M.capture(self.tree, self.captures, self.sdk_map, self.sdk_root,
                  self.native_capture, first)
        native = json.loads(self.native_capture.read_text())
        native["invocations"].reverse()
        self.native_capture.write_text(json.dumps(native))
        M.capture(self.tree, self.captures, self.sdk_map, self.sdk_root,
                  self.native_capture, second)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(len(json.loads(first.read_bytes())), 4)
        leaves = lambda root: {path.relative_to(root).as_posix(): path.read_bytes()
                               for path in root.rglob("*") if path.is_file()}
        self.assertEqual(leaves(first.parent), leaves(second.parent))

    def test_selected_c_object_retains_actual_argv_depfile_and_sdk_header_mapping(self):
        dep = ".build/native.o: Sources/native.c include/copied.h\n"
        _, argv_file = self.add_c_invocation(dep)
        rows = M.capture(self.tree, self.captures, self.sdk_map, self.sdk_root,
                         self.native_capture, self.output)
        c_row = next(row for row in rows if row["objectSHA256"] == self.sha(b"native-c-object"))
        document, prefix = M.V.compiler_input_document(
            c_row, lambda name: (self.output.parent / name).read_bytes())
        self.assertEqual(document["translationUnits"], [dict(
            project=M.V.parse((HERE / "runtime-native-source-licenses.json").read_bytes())
                ["containerization"]["identity"],
            path="vminitd/Sources/native.c", sha256=self.sha((self.tree / "Sources/native.c").read_bytes()))])
        self.assertEqual(document["sourceFiles"] and len(document["sourceFiles"]), 2)
        self.assertEqual(prefix, "")
        header = next(item for item in document["generatedHeaders"] if item["kind"] == "copied-header")
        self.assertEqual(header["matchingSources"], [self.sdk_header])
        retained = {item["file"]["sha256"]: item["file"] for item in header["retainedEvidence"]}
        self.assertIn(self.sha(dep.encode()), retained)
        self.assertIn(self.sha(argv_file.read_bytes()), retained)
        retained_argv = next(record for record in header["retainedEvidence"]
                             if record["file"]["sha256"] == self.sha(argv_file.read_bytes()))
        self.assertEqual((self.output.parent / retained_argv["file"]["path"]).read_bytes(),
                         argv_file.read_bytes())
        M.V.native_source_files(c_row, lambda name: (self.output.parent / name).read_bytes())

    def test_reused_generated_sdk_header_does_not_attribute_sibling_sdk_translation_units(self):
        dep = ".build/native.o: Sources/native.c include/generated.h\n"
        self.add_c_invocation(dep)

        template = dict(project="sdk-project", path="include/generated-template.h",
                        sha256=self.sha(b"/* SDK header template */\n"))
        sibling = dict(project="sdk-sibling", path="src/sibling.c",
                       sha256=self.sha(b"int sibling(void) { return 0; }\n"))
        generated_data = b"/* generated from the SDK template */\n#define SDK_VALUE 7\n"
        generated_evidence = b"generator input: include/generated-template.h\n"
        generated_file = self.sdk_root / "generated-config.h"
        generated_file.write_bytes(generated_data)
        generator_file = self.sdk_root / "generated-config.inputs"
        generator_file.write_bytes(generated_evidence)
        sdk_document = dict(
            objectSHA256=self.sdk_object["objectSHA256"],
            sourceFiles=[self.sdk_source, self.sdk_header, template, sibling],
            translationUnits=[self.sdk_source, sibling],
            generatedHeaders=[dict(
                originalPath="/sdk/build/include/generated.h",
                file=dict(path=generated_file.name, sha256=self.sha(generated_data),
                          sizeBytes=len(generated_data)),
                kind="generated-sdk-header", sourceFiles=[template],
                compilerArguments=["sdk-header-generator", "include/generated-template.h"],
                cwd="/sdk/build", evidence=dict(generatorInput="include/generated-template.h"),
                retainedEvidence=[dict(originalPath="/sdk/build/generated-config.inputs", file=dict(
                    path=generator_file.name, sha256=self.sha(generated_evidence),
                    sizeBytes=len(generated_evidence)))])])
        sdk_evidence = self.sdk_root / "compiler-inputs.json"
        sdk_evidence.write_bytes(M.V.canonical(sdk_document))
        self.sdk_object["sourceFiles"] = [self.sdk_source, sibling]
        self.sdk_object["compilerInputs"] = dict(
            path=sdk_evidence.name, sha256=self.sha(sdk_evidence.read_bytes()),
            sizeBytes=sdk_evidence.stat().st_size)
        sdk_capture = json.loads(self.sdk_map.read_text())
        sdk_capture["sourceMap"] = [self.sdk_object]
        self.sdk_map.write_text(json.dumps(sdk_capture))
        generated_in_tree = self.tree / "include" / "generated.h"
        generated_in_tree.write_bytes(generated_data)

        rows = M.capture(self.tree, self.captures, self.sdk_map, self.sdk_root,
                         self.native_capture, self.output)
        c_row = next(row for row in rows if row["objectSHA256"] == self.sha(b"native-c-object"))
        document, _ = M.V.compiler_input_document(
            c_row, lambda name: (self.output.parent / name).read_bytes())
        source_identities = {(row["project"], row["path"]) for row in document["sourceFiles"]}
        native_project = M.V.parse((HERE / "runtime-native-source-licenses.json").read_bytes())[
            "containerization"]["identity"]
        self.assertEqual(source_identities, {
            (native_project, "vminitd/Sources/native.c"),
            (template["project"], template["path"]),
        })
        self.assertEqual(document["translationUnits"], [dict(
            project=native_project, path="vminitd/Sources/native.c",
            sha256=self.sha((self.tree / "Sources/native.c").read_bytes()))])
        generated = next(row for row in document["generatedHeaders"]
                         if row["kind"] == "generated-sdk-header")
        self.assertEqual(generated["sourceFiles"], [template])
        self.assertEqual(generated["file"]["sha256"], self.sha(generated_data))
        retained_generator = next(row for row in generated["retainedEvidence"]
                                  if row["file"]["sha256"] == self.sha(generated_evidence))
        self.assertEqual((self.output.parent / retained_generator["file"]["path"]).read_bytes(),
                         generated_evidence)
        self.assertNotIn((self.sdk_source["project"], self.sdk_source["path"]), source_identities)
        self.assertNotIn((sibling["project"], sibling["path"]), source_identities)
        M.V.native_source_files(c_row, lambda name: (self.output.parent / name).read_bytes())

    def test_c_compiler_response_file_is_expanded_and_retained(self):
        self.add_c_invocation(".build/native.o: Sources/native.c include/copied.h\n")
        native = json.loads(self.native_capture.read_text())
        response = self.root / "compile.rsp"
        response.write_text("-c Sources/native.c -MF .build/native.d -o .build/native.o")
        argv = self.root / "native-argv.json"
        argv.write_bytes(M.V.canonical(["clang", "@" + str(response)]))
        invocation = native["invocations"][0]
        invocation["argv"].update(sha256=self.sha(argv.read_bytes()), sizeBytes=argv.stat().st_size)
        invocation["responseFiles"] = [dict(originalPath=str(response), file=dict(
            path=response.name, sha256=self.sha(response.read_bytes()), sizeBytes=response.stat().st_size))]
        self.native_capture.write_text(json.dumps(native))
        rows = M.capture(self.tree, self.captures, self.sdk_map, self.sdk_root,
                         self.native_capture, self.output)
        row = next(row for row in rows if row["objectSHA256"] == self.sha(b"native-c-object"))
        doc, _ = M.V.compiler_input_document(row, lambda name: (self.root / name).read_bytes())
        header = doc["generatedHeaders"][0]
        self.assertIn("-c", header["compilerArguments"])
        self.assertIn(self.sha(response.read_bytes()), [item["file"]["sha256"] for item in header["retainedEvidence"]])

    def test_selected_c_object_requires_retained_dependency_file(self):
        self.add_c_invocation(".build/native.o: Sources/native.c\n", retain_depfile=False)
        with self.assertRaisesRegex(ValueError, "lacks retained compiler dependencies"):
            M.capture(self.tree, self.captures, self.sdk_map, self.sdk_root,
                      self.native_capture, self.output)

    def test_selected_c_object_rejects_tampered_retained_dependency_file(self):
        self.add_c_invocation(".build/native.o: Sources/native.c\n")
        retained = self.root / "native-depfile.d"
        retained.write_text(".build/native.o: Sources/other.c\n")
        with self.assertRaisesRegex(ValueError, "evidence bytes mismatch"):
            M.capture(self.tree, self.captures, self.sdk_map, self.sdk_root,
                      self.native_capture, self.output)

    def test_selected_c_object_rejects_unrecognized_header_dependency(self):
        unknown = self.tree / "include" / "unrecorded.h"
        unknown.parent.mkdir(parents=True)
        unknown.write_text("/* not in the retained SDK source evidence */\n")
        self.add_c_invocation(".build/native.o: Sources/native.c include/unrecorded.h\n")
        with self.assertRaisesRegex(ValueError, "compiler dependency lacks captured source or SDK generation evidence"):
            M.capture(self.tree, self.captures, self.sdk_map, self.sdk_root,
                      self.native_capture, self.output)

    def test_fails_when_selected_sdk_member_has_no_source_mapping(self):
        value = json.loads(self.sdk_map.read_text())
        value["sourceMap"] = []
        self.sdk_map.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "no source mapping"):
            M.capture(self.tree, self.captures, self.sdk_map, self.sdk_root,
                      self.native_capture, self.output)


if __name__ == "__main__":
    unittest.main()
