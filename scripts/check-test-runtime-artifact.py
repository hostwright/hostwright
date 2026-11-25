#!/usr/bin/env python3
"""Reject test-only recording runtime markers in a Mach-O binary."""

import argparse
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory


PROVIDER_ID = "hostwright-test-recording-v1"
SYMBOL_MARKERS = ("HostwrightTestRecordingRuntime", "HostwrightTestRuntimeCommand")
MACH_O_MAGICS = {
    bytes.fromhex(magic) for magic in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )
}


def scan(binary: Path) -> list[str]:
    binary = binary.resolve(strict=True)
    if not binary.is_file():
        raise ValueError(f"{binary} is not a regular file")
    with binary.open("rb") as artifact:
        if artifact.read(4) not in MACH_O_MAGICS:
            raise ValueError(f"{binary} is not a Mach-O binary")

    symbols = subprocess.run(
        ["/usr/bin/nm", "-arch", "all", "-j", "--", str(binary)],
        capture_output=True, check=True,
    ).stdout
    literals = subprocess.run(
        ["/usr/bin/strings", "-a", "--", str(binary)],
        capture_output=True, check=True,
    ).stdout

    findings = [
        marker for marker in SYMBOL_MARKERS
        if marker.encode("ascii") in symbols or marker.encode("ascii") in literals
    ]
    if PROVIDER_ID.encode("ascii") in literals:
        findings.append(PROVIDER_ID)
    return findings


def self_test() -> None:
    fixtures = [
        ("clean", "int main(void) { return 0; }", [], False),
        ("provider-id", f'#include <stdio.h>\nint main(void) {{ return puts("{PROVIDER_ID}"); }}', [PROVIDER_ID], True),
    ]
    for marker in SYMBOL_MARKERS:
        fixtures.append((marker, f"int {marker}Probe(void) {{ return 0; }}\n"
                         f"int main(void) {{ return {marker}Probe(); }}", [marker], False))
        fixtures.append((f"{marker}-stripped", f'#include <stdio.h>\nint main(void) {{ return puts("{marker}"); }}',
                         [marker], True))

    with TemporaryDirectory(prefix="hostwright-test-runtime-artifact-") as directory:
        for name, source, expected, strip in fixtures:
            binary = Path(directory) / name
            subprocess.run(
                ["/usr/bin/clang", "-O2", "-x", "c", "-", "-o", str(binary)],
                input=source.encode("ascii"), capture_output=True, check=True,
            )
            if strip:
                subprocess.run(["/usr/bin/strip", str(binary)], capture_output=True, check=True)
            findings = scan(binary)
            if findings != expected:
                raise ValueError(f"{name} fixture expected {expected}, found {findings}")
    print("test-runtime artifact self-test passed: clean binary, provider ID, and type names in symbols and strings")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("binary", nargs="?", type=Path)
    mode.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    try:
        if args.self_test:
            self_test()
            return 0
        findings = scan(args.binary)
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode(errors="replace").strip()
        print(f"test-runtime artifact check: {error.cmd[0]} failed ({error.returncode}): {detail}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        print(f"test-runtime artifact check: {error}", file=sys.stderr)
        return 1

    if findings:
        print(f"test-runtime artifact check failed for {args.binary}: found {', '.join(findings)}", file=sys.stderr)
        return 1
    print(f"test-runtime artifact check passed for {args.binary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
