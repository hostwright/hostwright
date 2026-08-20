# Phase 15 release qualification

This document describes the additive release-qualification boundary introduced for issues #271, #273, #274, and #275. It is a source-only qualification tool and contract library. It does not close Phase 15 or authorize a release.

## Scope and authority

The committed compatibility truth is intentionally narrow:

| Dimension | Committed values |
| --- | --- |
| Release target | `v0.0.2` |
| macOS | major version `26` |
| Hardware | Apple silicon |
| Architecture | `arm64` |
| Apple container CLI | `1.0.0`, `1.1.0` |
| Containerization framework | `0.35.0` |
| Other clients and platforms | no supported claims in this slice |

The three committed cells require live-runtime, migration/upgrade, security-assessment, and resilience/chaos evidence. The detector verifies that the source contains the released Phase 08 main checkpoint `00f95eaabd105f17f61727d2a9899db919ad3d9f`; this is an ancestry fact, not runtime evidence. The executable still never starts Apple Container, a Hostwright daemon, Docker Desktop, a VM, a signing toolchain, or a public-release action without a future explicit provider and evidence handoff.

The Swift contracts in `Sources/HostwrightReleaseQualification` are normative. [`schemas/hostwright-release-qualification.schema.json`](../../schemas/hostwright-release-qualification.schema.json) is the machine-readable companion schema; unknown fields, future schema versions, malformed values, unsafe paths, and non-canonical JSON fail closed.

## Executable contract

Build and invoke the executable with SwiftPM:

```bash
swift build --jobs 1 --product hostwright-release-qualify
swift run --jobs 1 hostwright-release-qualify plan --root "$PWD"
swift run --jobs 1 hostwright-release-qualify detect --root "$PWD"
```

Commands are bounded and write only stdout/stderr unless an explicit private ledger root is supplied.

| Command | Behavior | Successful output |
| --- | --- | --- |
| `plan` | Reads the committed matrix, registry, and seeded corpus identities. | Canonical plan JSON; lanes without providers remain `blocked`. |
| `detect` | Reads source, host, framework, and safely queryable tool facts. | Canonical environment and per-cell evaluations. |
| `verify --cell ID` | Detects, evaluates one committed cell, and records a real result. | Evidence JSON. Live/heavy/authority cells are blocked, never simulated as passed. |
| `verify --cell ID --execute-safe-checks` | Adds the wired local dependency and bounded secret checks. | Evidence includes their actual pass/fail/block result. |
| `status --ledger-root PATH` | Reads an existing private ledger. | Canonical ledger summary. |
| `resume --ledger-root PATH` | Recovers running journals to `interrupted` and reports the summary. | Canonical recovery report. |

`verify` accepts `--ledger-root PATH --run-id ID` to atomically persist one result. The ledger root must be an explicit absolute private directory; the executable does not choose a global default. Exit code `64` is usage, `69` is blocked, `70` is failed, and `75` is stale evidence.

## Evidence and ledger rules

Every evidence record binds:

- the exact source commit and dirty-state digest;
- detected host, framework, and tool facts;
- exactly one required evidence class; a single report cannot satisfy every class in a matrix claim;
- explicit executable, argument, working-directory, timing, exit, truncation, and raw-output hashes for every command;
- the claim identity, execution mode, authority, simulation class, replay key, blockers, failures, and owned artifact paths;
- bounded timestamps and duration.

Only `passed` + `real` evidence from an available clean source tree with no blockers or failures satisfies a required gate. `mock`, `fixture`, `dirty`, `stale`, `unavailable`, `skipped`, `cancelled`, and `blocked` outcomes remain visible but cannot satisfy one.

The private ledger uses `0700` directories, a per-ledger owner record, `0600` canonical journal files, envelope hashes, atomic exclusive temporary publication, interruption recovery, replay/idempotency, conflict detection, and current-environment verification. Artifact cleanup preflights the exact relative path, owner marker, size, and hash; it removes only the recorded artifact and its marker. Unmanaged files are retained.

## Gate registry

The default registry is plan-visible and fail-closed:

| Lane | Local behavior | Current boundary |
| --- | --- | --- |
| Qualification/evidence JSON boundary | Strict canonical decode with accept/reject seeded corpus identities. | Executable locally. |
| Dependency lock integrity | Checks exact direct pins, resolved origin hash, unique pins, versions, revisions, and bounds. | Executable locally; it is not provenance or license evidence. |
| Secret scan | Bounded high-confidence pattern scan with no secret contents in the report. | Executable locally; it reports findings as failures. The base test tree contains intentionally secret-shaped AWS/GitHub fixture strings, so a clean scan result is not assumed. |
| Phase 08 protocol fuzz | Plan only. | Phase 08 authority is released; the lane remains blocked by the absent bounded fuzzing provider and corpus. |
| ASan/TSan | Plan only. | Blocked; no sanitizer provider is wired. |
| Semgrep/SAST | Plan only unless a safe provider is explicitly supplied. | Blocked when unavailable; tool presence alone cannot pass the lane. |
| License metadata | Plan only. | Blocked; no authoritative metadata provider is wired. |

The registry records budgets, exclusions, corpus paths, sizes, and SHA-256 identities. It does not claim 24-hour fuzzing, ASan/TSan execution, an independent assessment, external supply-chain evidence, signing/notarization, or public submission.

## Focused verification

The narrow local check is:

```bash
scripts/phase15-release-qualification.sh
```

It runs `swift package dump-package`, a serial product build, the filtered `HostwrightReleaseQualificationTests` target, canonical plan decoding, the JSON schema parse check, and `git diff --check`. It does not run the repository-wide suite or any live runtime.

Remaining Phase 15 evidence gates include final convergence, long-duration fuzz/soak runs, physical multi-host and hardware qualification, independent security assessment, signing/notarization, trusted GA artifacts, and Homebrew submission.
