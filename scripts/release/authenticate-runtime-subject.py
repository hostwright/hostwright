#!/usr/bin/env python3
"""Authenticate an intermediate subject against its original producer attempt."""
import argparse
import importlib.util
from pathlib import Path


spec = importlib.util.spec_from_file_location("runtime_provenance", Path(__file__).with_name("verify-runtime-provenance.py"))
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--attempt", type=int, required=True)
    args = parser.parse_args()
    verifier.authenticate(args.file, dict(commit=args.source_commit, runID=args.run_id, attempt=args.attempt),
                          args.source_commit)
