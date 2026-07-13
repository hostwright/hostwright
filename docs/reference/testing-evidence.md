# Testing And Evidence

Hostwright separates deterministic test coverage from evidence that exercises real local systems. A report uses exactly one evidence class:

| Evidence class | What it proves | What it cannot prove |
| --- | --- | --- |
| `unit-contract` | Deterministic logic, parsing, policy, redaction, failure injection, clocks, retries, and recovery branches. | Real process, database, Keychain, Apple container, hardware, or artifact behavior. |
| `local-integration` | Real local files, subprocesses, loopback networking, SQLite connections, file locks, or Keychain operations. | Apple container mutation, hardware efficiency, signing, notarization, or installation artifacts unless those systems were exercised. |
| `live-runtime` | Real runtime behavior against uniquely named disposable Hostwright-owned resources with exact cleanup. | Unmeasured hardware efficiency, provider behavior, or distribution trust. |
| `hardware-benchmark` | Measured work on the recorded physical hardware with raw samples and exact tool versions. | Capacity guarantees, other hardware, or accelerator behavior that was not directly measured. |
| `distribution-artifact` | Actual build, checksum, SBOM/provenance, signing, notarization, install, upgrade, downgrade, and uninstall stages that ran. | Any stage recorded as blocked or failed. |
| `migration-upgrade` | Real forward migration, upgrade, rollback-window, backup, restore, and mixed-version behavior using retained fixtures or artifacts from supported versions. | A schema unit test alone, an invented old fixture, or a downgrade path that did not execute. |
| `security-assessment` | Threat-model checks, adversarial tests, fuzzing, static analysis, dependency review, penetration work, and remediation evidence for the reviewed boundary. | A general claim that an unreviewed component or deployment is secure. |
| `resilience-chaos` | Recovery under injected process, storage, network, timing, cancellation, and checkpoint failures with bounded convergence and exact cleanup. | Availability outside the injected fault model or a soak that did not complete. |
| `multi-host` | Behavior on the recorded physical Mac cluster, including quorum, fencing, failover, partitions, identity, upgrades, and exact cluster cleanup. | A simulated cluster, multiple processes on one Mac, or unsafe behavior during quorum loss. |
| `interop-conformance` | Results from the named upstream conformance suite and exact client/server/version matrix against real Hostwright behavior. | Compatibility with untested endpoints, versions, clients, or silently ignored fields. |
| `ux-accessibility` | Completed user workflows, API-parity checks, accessibility inspection, assistive-technology testing, and recorded platform/version scope. | Visual review alone or accessibility claims for untested workflows. |

Reports conform to `schemas/hostwright-evidence.schema.json`; production Swift models and validation live in `HostwrightCore/EvidenceModels.swift`. Status is one of `passed`, `failed`, or `blocked`; there is no skipped-success status.

The default repository gate runs `swift test` for unit-contract and XCTest-backed local integration coverage, then `scripts/integration.sh` against the built tools. Distribution tests exercise actual debug Hostwright binaries, tar archives, checksums, subprocesses, permission failures, and temporary prefixes, but remain local-integration evidence because they use dirty prebuilt assembly and no signing/notarization credentials. `hostwright-dist build` is the separate clean release-build lane. `hostwright benchmark` similarly separates scripted contracts from hardware evidence.

## Passing Rules

A passing report must:

- identify the exact source commit and whether the worktree was dirty;
- record OS, architecture, hardware, memory, and relevant tool versions;
- include every command and its real exit status;
- include raw executed, passed, failed, and blocked counts;
- contain no failures or blockers;
- record cleanup as `not-required` or `succeeded`;
- use evidence from the declared class, not a fixture standing in for a higher class.

Release evidence must come from a clean checkout. A dirty report can support development diagnosis but cannot satisfy a release gate.

## Failure And Blocking Rules

- A command failure makes the report `failed` and records a redacted failure message.
- A missing executable, image, credential, signing identity, provider account, second host, permission, or other prerequisite makes the report `blocked`.
- Blocked work may not be converted to passed with a fixture, no-op implementation, conditional early return, or silently skipped test.
- Exact cleanup failure makes live-runtime, hardware, resilience-chaos, multi-host, or interoperability evidence fail even when the measured operation succeeded.
- Unit and contract tests may use scripted dependencies when a real dependency cannot deterministically produce the required failure. Their output remains `unit-contract` evidence.
- A successful unsigned archive or temp-prefix lifecycle remains `blocked` when Developer ID signing, notarization, stapling, Gatekeeper, installer, or publication stages did not run.
- Distribution cleanup must restore the explicit temporary prefix to its initial unrelated-content snapshot; an owned-file cleanup or rollback failure is not a passing lifecycle.
- Migration evidence must use an artifact or fixture produced by the recorded prior contract, exercise the real migration path, verify retained data, and prove the documented rollback window.
- Multi-host evidence must identify every physical node, prove that mutation stops without quorum, and record fencing-token behavior after recovery.
- Interoperability evidence must name the upstream suite, client, protocol version, unsupported surface, raw pass/fail counts, and exact cleanup.
- UX/accessibility evidence must name the workflow, macOS version, input method or assistive technology, observed result, and parity contract.

## Closure Evidence

Every roadmap child, epic, and release gate declares the evidence classes it requires. Research, design, or documentation can inform an implementation issue, but cannot close it. A final issue evidence comment and a closing PR use this stable marker:

```text
<!-- hostwright-evidence-gate:v1 -->
```

The evidence comment records the exact commit, `Dirty: false`, OS, hardware, runtime and framework versions, commands, raw outcomes, failures, blockers, and cleanup. `Blocked`, `skipped`, fixture-only, mock-only, dirty, or cleanup-failed results never satisfy a required class. Intermediate PRs use `Refs #NN`; only the final verification PR can use `Closes #NN`.

## Evidence Storage

Schemas, runners, and sanitized reviewed evidence may be committed. Machine-local paths, hostnames, account names, credentials, raw secrets, and unrelated resource identifiers must not be committed. CI or release artifacts retain full command logs after redaction; public docs summarize only evidence that passed for the exact reviewed commit.
