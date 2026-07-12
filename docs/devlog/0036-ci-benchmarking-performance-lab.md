# Phase 36: CI Benchmarking And Performance Lab

## Summary

Phase 36 now has an operational local benchmark runner. Hosted CI still runs deterministic and local-integration gates only; it does not claim hardware evidence.

## What Changed

- Added typed evidence models for all five evidence classes and fail-closed status validation.
- Added schema-v2 benchmark reports with source/environment facts, command durations, raw counts, blockers/failures, raw iterations, and exact cleanup.
- Added `hostwright benchmark` with explicit local image, 3-10 samples, output path, source commit/dirty state, expected Apple container version, and live confirmation.
- Added RuntimeAdapter-backed real Apple container version and exact-resource non-streaming JSON stats probes.
- Added local image reference, descriptor digest, platform-variant digest, architecture, and OS evidence before mutation.
- Added real IOKit battery and ProcessInfo thermal facts.
- Added optional attended sleep/wake gap detection and exact post-wake resource observation without forcing system sleep.
- Kept schema-v1 fixture parsing as unit-contract history only.
- Hardened process termination detection after a live output-complete timeout exposed unreliable cross-thread `waitUntilExit()` behavior.
- Added parser, direct-command, redaction, blocked-capability, cleanup-failure, real-file overwrite, real-host-probe, stats-shape, and rapid-process tests.

## Live Evidence

A local dirty-tree development run against Apple container 1.0.0 and the existing `docker.io/library/python:alpine` image completed three requested iterations, measured six dimensions, recorded no command failures, deleted all three exact identifiers, and left no benchmark resources. The report remained `blocked` because no attended sleep occurred. This development result proves the runner path, not release readiness; a clean-source passing report is still required for any public benchmark claim.

A second run used a clean detached worktree at implementation commit `2f7b0d103f8f8b5e62f665767fb10be97c49d06a`. It completed all three requested iterations, recorded the local image descriptor and ARM64 variant digests, recorded no failures, deleted every exact identifier, verified their absence, and left the pre-existing runtime inventory unchanged. The attended window ran, but wall time and monotonic uptime were equal because the Mac did not sleep. The report therefore exited blocked with sleep/wake as its only blocker. The mode-`0600` machine-local report is not committed and does not satisfy the public benchmark gate.

## Safety Boundaries

- No image pull.
- No broad, force, image, volume, network, or unmanaged cleanup.
- No state database.
- No telemetry or upload.
- No hosted hardware execution.
- No fixture or scripted hardware pass.
- No benchmark publication, performance comparison, efficiency claim, or capacity claim.
- No dependencies, release tags, GitHub Releases, website work, or GUI code.

## Remaining Evidence

Physical sleep/wake has not been observed on the reviewed implementation commit. Runtime density, VM overhead, sustained battery/thermal behavior, accelerator performance, and production capacity remain unmeasured and unsupported.
