# Testing And Evidence

Hostwright separates deterministic test coverage from evidence that exercises real local systems. A report uses exactly one evidence class:

| Evidence class | What it proves | What it cannot prove |
| --- | --- | --- |
| `unit-contract` | Deterministic logic, parsing, policy, redaction, failure injection, clocks, retries, and recovery branches. | Real process, database, Keychain, Apple container, hardware, or artifact behavior. |
| `local-integration` | Real local files, subprocesses, loopback networking, SQLite connections, file locks, or Keychain operations. | Apple container mutation, hardware efficiency, signing, notarization, or installation artifacts unless those systems were exercised. |
| `live-runtime` | Real runtime behavior against uniquely named disposable Hostwright-owned resources with exact cleanup. | Unmeasured hardware efficiency, provider behavior, or distribution trust. |
| `hardware-benchmark` | Measured work on the recorded physical hardware with raw samples and exact tool versions. | Capacity guarantees, other hardware, or accelerator behavior that was not directly measured. |
| `distribution-artifact` | Actual build, checksum, SBOM/provenance, signing, notarization, install, upgrade, downgrade, and uninstall stages that ran. | Any stage recorded as blocked or failed. |

Reports conform to `schemas/hostwright-evidence.schema.json`; production Swift models and validation live in `HostwrightCore/EvidenceModels.swift`. Status is one of `passed`, `failed`, or `blocked`; there is no skipped-success status.

The default repository gate runs `swift test` for unit-contract and XCTest-backed local integration coverage, then `scripts/integration.sh` against the built CLI. Live runtime, hardware, and distribution lanes remain separate because they require explicit resources or credentials. `hostwright benchmark` can create a hardware report locally, but its scripted contract tests never count as that report's proof.

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
- Exact cleanup failure makes live-runtime or hardware evidence fail even when the measured operation succeeded.
- Unit and contract tests may use scripted dependencies when a real dependency cannot deterministically produce the required failure. Their output remains `unit-contract` evidence.

## Evidence Storage

Schemas, runners, and sanitized reviewed evidence may be committed. Machine-local paths, hostnames, account names, credentials, raw secrets, and unrelated resource identifiers must not be committed. CI or release artifacts retain full command logs after redaction; public docs summarize only evidence that passed for the exact reviewed commit.
