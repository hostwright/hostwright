# Phase 34 Devlog: Enterprise And Team Workflow

Date: 2026-07-12

## Scope

Phase 34 now implements an explicit local team review workflow rather than only in-memory policy models.

Implemented:

- strict versioned JSON profile and approval parsers;
- unknown-field and missing-field rejection;
- canonical SHA-256 profile and approval hashes plus exact manifest hashes;
- strict-only `requireImageDigest` and `requireManifestReview` profile requirements;
- explicit profile loading for validate, plan, import, apply, and cleanup;
- exact approval binding for profile-aware apply and confirmed cleanup;
- profile, manifest, plan, and approval hashes in runtime confirmations and redacted append-only audit records;
- ownership and confirmation tests proving approval cannot bypass core gates;
- real temporary-file and SQLite integration plus built-CLI subprocess coverage.

The earlier reviewed-weakening model was removed. Approval records document and authorize one exact reviewed operation; they never relax policy.

## Evidence

- Policy parser/evaluator tests use real JSON decoding and deterministic canonical hashing.
- CLI integration tests read profile and approval files from real temporary paths.
- Apply and cleanup audit tests use real migrated SQLite databases and query persisted operation/event rows.
- The mutation adapter used by XCTest is limited to capturing confirmation metadata; it is not counted as live-runtime evidence.
- `scripts/integration.sh` runs the built executable against real profile and stack files and verifies no hidden state write.

## Boundaries Preserved

- No profile or approval default path.
- No policy weakening or safety bypass.
- No cloud team service, remote control, hosted audit log, tracking, or remote policy distribution.
- No direct Apple container shell-out outside `RuntimeAdapter`.
- No SQLite access outside `HostwrightState`.
- No new runtime action, dependency, release tag, or GitHub Release.

## Verification

```bash
swift build
swift test list
swift test
scripts/grep-orchard.sh .
scripts/test.sh
scripts/lint.sh
```

Targeted gates include `TeamWorkflowPolicyTests`, `TeamWorkflowCLITests`, and `scripts/integration.sh`.
