#!/usr/bin/env python3
"""Validate that shipped product closures cannot reach Foundation.Process."""

from __future__ import annotations

import json
import re
import sys
import tempfile
from pathlib import Path
from typing import Any


QUALIFICATION_TARGET = "HostwrightPhase09QualificationTool"
QUALIFICATION_PATH = "Qualification/HostwrightPhase09QualificationTool"
QUALIFICATION_TARGET_PATHS = {
    "HostwrightLocalIntegrationTool": "Qualification/HostwrightLocalIntegrationTool",
    "HostwrightPhase09QualificationTool": QUALIFICATION_PATH,
    "HostwrightTunnelQualificationTool": "Tests/HostwrightTunnelQualificationTool",
}
NON_PRODUCT_QUALIFICATION_TARGETS = {
    "HostwrightLocalIntegrationTool",
    QUALIFICATION_TARGET,
}
TEST_SUPPORT_TARGET = "HostwrightTestSupport"
TEST_SUPPORT_PATH = "Tests/HostwrightTestSupport"
PROCESS_CALL = re.compile(r"(?:\bFoundation\s*\.\s*)?\bProcess\s*\(")


class BoundaryError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BoundaryError(message)


def dependency_name(dependency: Any, local_names: set[str]) -> str | None:
    require(isinstance(dependency, dict) and len(dependency) == 1, "unknown target dependency shape")
    kind, value = next(iter(dependency.items()))
    if kind == "target":
        require(isinstance(value, list) and value and isinstance(value[0], str), "invalid target dependency")
        require(value[0] in local_names, f"unknown local target dependency: {value[0]}")
        return value[0]
    if kind == "byName":
        require(isinstance(value, list) and value and isinstance(value[0], str), "invalid by-name dependency")
        require(value[0] in local_names, f"ambiguous nonlocal by-name dependency: {value[0]}")
        return value[0]
    if kind == "product":
        require(isinstance(value, list) and value and isinstance(value[0], str), "invalid product dependency")
        return None
    raise BoundaryError(f"unknown target dependency kind: {kind}")


def target_path(target: dict[str, Any]) -> str:
    name = target.get("name")
    require(isinstance(name, str) and name, "target has no name")
    configured = target.get("path")
    if configured is None:
        return f"Tests/{name}" if target.get("type") == "test" else f"Sources/{name}"
    require(isinstance(configured, str) and configured, f"target {name} has invalid path")
    path = Path(configured)
    require(not path.is_absolute() and ".." not in path.parts, f"target {name} path escapes repository")
    normalized = path.as_posix().rstrip("/")
    require(normalized == configured.rstrip("/"), f"target {name} path is noncanonical")
    return normalized


def swift_files(root: Path, relative_path: str, explicit_sources: Any) -> list[Path]:
    base = root / relative_path
    require(base.is_dir(), f"target path does not exist: {relative_path}")
    if explicit_sources is None:
        return sorted(base.rglob("*.swift"))
    require(isinstance(explicit_sources, list), f"invalid sources for {relative_path}")
    files: list[Path] = []
    for source in explicit_sources:
        require(isinstance(source, str) and source, f"invalid source in {relative_path}")
        candidate = base / source
        require(candidate.is_file() and candidate.suffix == ".swift", f"missing Swift source: {candidate}")
        require(candidate.resolve().is_relative_to(base.resolve()), f"source escapes target: {candidate}")
        files.append(candidate)
    return sorted(files)


def validate(package: dict[str, Any], root: Path) -> None:
    targets = package.get("targets")
    products = package.get("products")
    require(isinstance(targets, list) and targets, "package contains no targets")
    require(isinstance(products, list) and products, "package contains no products")

    target_map: dict[str, dict[str, Any]] = {}
    paths: dict[str, str] = {}
    for target in targets:
        require(isinstance(target, dict), "invalid target entry")
        name = target.get("name")
        require(isinstance(name, str) and name not in target_map, f"duplicate or invalid target: {name}")
        target_map[name] = target
        paths[name] = target_path(target)

    require(QUALIFICATION_TARGET in target_map, "qualification target is missing")
    for name, target in target_map.items():
        if target.get("type") == "test":
            continue
        path = paths[name]
        if name in QUALIFICATION_TARGET_PATHS:
            require(path == QUALIFICATION_TARGET_PATHS[name],
                    f"{name} must use its exact qualification path")
        elif name == TEST_SUPPORT_TARGET:
            require(path == TEST_SUPPORT_PATH, "test support target must use its exact Tests path")
        else:
            require(path.startswith("Sources/") and path.count("/") >= 1,
                    f"non-test target outside Sources: {name} -> {path}")

    local_dependencies: dict[str, set[str]] = {}
    local_names = set(target_map)
    for name, target in target_map.items():
        dependencies = target.get("dependencies", [])
        require(isinstance(dependencies, list), f"target {name} has invalid dependencies")
        local_dependencies[name] = {
            dependency
            for item in dependencies
            if (dependency := dependency_name(item, local_names)) is not None
        }

    product_roots: list[tuple[str, list[str]]] = []
    for product in products:
        require(isinstance(product, dict), "invalid product entry")
        name = product.get("name")
        roots = product.get("targets")
        require(isinstance(name, str) and isinstance(roots, list) and roots,
                "product has no valid target roots")
        require(all(isinstance(item, str) and item in target_map for item in roots),
                f"product {name} names an unknown local target")
        product_roots.append((name, roots))

    scanned: set[str] = set()
    for product_name, roots in product_roots:
        closure: set[str] = set()
        pending = list(roots)
        while pending:
            name = pending.pop()
            if name in closure:
                continue
            require(name in target_map, f"product {product_name} reaches unknown target {name}")
            closure.add(name)
            require(name != TEST_SUPPORT_TARGET,
                    f"product {product_name} reaches test-only support target")
            pending.extend(sorted(local_dependencies[name]))
        for qualification_target in NON_PRODUCT_QUALIFICATION_TARGETS:
            require(qualification_target not in closure,
                    f"product {product_name} reaches qualification target")
        scanned.update(closure)

    for name in sorted(scanned):
        target = target_map[name]
        for source in swift_files(root, paths[name], target.get("sources")):
            content = source.read_text(encoding="utf-8")
            require(PROCESS_CALL.search(content) is None,
                    f"shipped product closure contains Process callsite: {source.relative_to(root)}")


def fixture(root: Path, *, dependency: str | None = None, product_target: str = "App") -> dict[str, Any]:
    (root / "Sources/App").mkdir(parents=True, exist_ok=True)
    (root / "Sources/Core").mkdir(parents=True, exist_ok=True)
    (root / QUALIFICATION_PATH).mkdir(parents=True, exist_ok=True)
    (root / "Sources/App/main.swift").write_text("print(\"ok\")\n", encoding="utf-8")
    (root / "Sources/Core/Core.swift").write_text("public struct Core {}\n", encoding="utf-8")
    (root / QUALIFICATION_PATH / "main.swift").write_text("let p = Process()\n", encoding="utf-8")
    dependencies: list[dict[str, Any]] = []
    if dependency is not None:
        dependencies.append({"target": [dependency, None]})
    return {
        "products": [{"name": "app", "targets": [product_target]}],
        "targets": [
            {"name": "App", "type": "executable", "dependencies": dependencies},
            {"name": "Core", "type": "regular", "dependencies": []},
            {"name": QUALIFICATION_TARGET, "type": "executable", "path": QUALIFICATION_PATH,
             "dependencies": []},
        ],
    }


def expect_failure(package: dict[str, Any], root: Path, fragment: str) -> None:
    try:
        validate(package, root)
    except BoundaryError as error:
        require(fragment in str(error), f"unexpected self-test failure: {error}")
        return
    raise BoundaryError(f"self-test unexpectedly passed: {fragment}")


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="hostwright-process-boundary-") as temporary:
        root = Path(temporary)
        package = fixture(root)
        validate(package, root)

        closure_leak = fixture(root, dependency=QUALIFICATION_TARGET)
        expect_failure(closure_leak, root, "reaches qualification target")

        process_call = fixture(root)
        (root / "Sources/Core/Core.swift").write_text("let process = Foundation.Process()\n", encoding="utf-8")
        process_call["targets"][0]["dependencies"] = [{"byName": ["Core", None]}]
        expect_failure(process_call, root, "Process callsite")

        wrong_path = fixture(root)
        wrong_path["targets"][2]["path"] = "Sources/HostwrightPhase09QualificationTool"
        expect_failure(wrong_path, root, "exact qualification path")

        outside_sources = fixture(root)
        outside_sources["targets"][1]["path"] = "Tools/Core"
        expect_failure(outside_sources, root, "outside Sources")

        unknown = fixture(root)
        unknown["targets"][0]["dependencies"] = [{"byName": ["Unknown", None]}]
        expect_failure(unknown, root, "ambiguous nonlocal")

        support = fixture(root)
        support["targets"].append({
            "name": TEST_SUPPORT_TARGET,
            "type": "regular",
            "path": TEST_SUPPORT_PATH,
            "dependencies": [],
        })
        (root / TEST_SUPPORT_PATH).mkdir(parents=True, exist_ok=True)
        validate(support, root)
        support_leak = fixture(root, dependency=TEST_SUPPORT_TARGET)
        support_leak["targets"].append({
            "name": TEST_SUPPORT_TARGET,
            "type": "regular",
            "path": TEST_SUPPORT_PATH,
            "dependencies": [],
        })
        (root / TEST_SUPPORT_PATH).mkdir(parents=True, exist_ok=True)
        expect_failure(support_leak, root, "test-only support target")

        tunnel = fixture(root, product_target="HostwrightTunnelQualificationTool")
        tunnel["targets"].append({
            "name": "HostwrightTunnelQualificationTool",
            "type": "executable",
            "path": "Tests/HostwrightTunnelQualificationTool",
            "dependencies": [],
        })
        (root / "Tests/HostwrightTunnelQualificationTool").mkdir(parents=True, exist_ok=True)
        validate(tunnel, root)

        integration_path = QUALIFICATION_TARGET_PATHS["HostwrightLocalIntegrationTool"]
        integration = fixture(root)
        integration["targets"].append({
            "name": "HostwrightLocalIntegrationTool",
            "type": "executable",
            "path": integration_path,
            "dependencies": [],
        })
        (root / integration_path).mkdir(parents=True, exist_ok=True)
        (root / integration_path / "main.swift").write_text("print(\"integration\")\n", encoding="utf-8")
        validate(integration, root)

        integration_product = fixture(root, product_target="HostwrightLocalIntegrationTool")
        integration_product["targets"].append({
            "name": "HostwrightLocalIntegrationTool",
            "type": "executable",
            "path": integration_path,
            "dependencies": [],
        })
        expect_failure(integration_product, root, "reaches qualification target")


def main() -> int:
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
            return 0
        require(not sys.argv[1:], "usage: check-shipped-process-boundary.py [--self-test]")
        package = json.load(sys.stdin)
        require(isinstance(package, dict), "dump-package input is not an object")
        validate(package, Path.cwd())
        return 0
    except (BoundaryError, OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"shipped-process-boundary: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
