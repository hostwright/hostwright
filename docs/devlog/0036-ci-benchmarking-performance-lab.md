# Phase 36: CI Benchmarking And Performance Lab

## Summary

Phase 36 adds a local benchmark lab report contract and fixture parser. It does not run live benchmarks or publish performance numbers.

## What Changed

- Added `BenchmarkLabReport` models in `HostwrightHealth`.
- Added parser validation for schema version, profile identity, Hostwright-owned disposable resource policy, no image pull, no runtime mutation, no broad cleanup, and complete benchmark dimensions.
- Added a Phase 36 benchmark fixture and XCTest coverage for dry-run reports and unsafe policy rejection.
- Added `docs/architecture/benchmark-lab.md`.
- Added `scripts/lint.sh` to hosted CI after build and test.

## Safety Boundaries

- No live Apple container benchmark command.
- No image pulls.
- No runtime mutation.
- No broad cleanup.
- No state writes.
- No cloud telemetry.
- No hosted performance monitoring.
- No benchmark numbers or performance marketing claims.
- No dependencies, release tags, GitHub Releases, website work, or GUI code.

## Blocked Evidence

Runtime density, VM overhead, boot latency, polling overhead, battery behavior, sleep/wake behavior, workload memory pressure, and Apple container version drift still require a separate approved live benchmark path with disposable resources and exact cleanup proof.
