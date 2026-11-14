# Staged v0.0.2 release promotion

Trusted staging builds unpublished final `0.0.2` artifacts from a clean reviewed
commit on main. The active qualification policy is
`hostwright.v0.0.2.focused.v1`, defined by [ADR 0017](../design/adr-0017-focused-v002-qualification.md).
No separate accepted RC, repeated timed campaign or agent-review receipt is required.

## Required reports

The private export contains exactly five group reports: `source.json`,
`artifact-integrity.json`, `installation.json`, `working-product.json` and
`documentation.json`. Each records `qualificationPolicy`, actual `sourceCommit`,
`version`, `status: passed`, `executionMode: real`, clean source before/after,
empty blockers/failures, `passedChecks` and hashed raw `attachments`.
`scripts/release/accept-qualification.py` defines the required outcomes.

All groups except source bind `inventorySHA256` to the staged bytes.
Installation, working product and documentation require `cleanupStatus: passed`.
Working product includes `providerChecks` for each declared provider with one
up/status/stats/logs/restart/down/owned-cleanup sequence. Artifact integrity
verifies the corresponding-source binding and zero unresolved P0/P1. Documentation
records the exact clean website commit and both packages' typecheck/build/link results.

Retain prior successes with their original source/artifact bindings. Reuse requires
unchanged relevant inputs and an explicit comparison; do not rewrite historical
receipts or claim a prior run executed the repaired candidate. Execute affected
artifact checks again after product changes.

## Assemble and retain

Create `qualification-inputs.json` with `kind: hostwright.qualification-inputs.v1`
and a `gates` map from each of the five group keys to its relative report path.
Attachments are relative to each raw report. Assembly validates real results
before creating an export and supplies no missing pass flags.

```bash
python3 scripts/release/assemble-qualification.py \
  --commit "$source_commit" --version "$release_version" \
  --run "$stage_run" --attempt "$stage_attempt" \
  --stage "$stage_bundle" --input-root "$raw_evidence" \
  --output "$private_export"
```

Copy the complete export to
`/Volumes/T9/hostwright/v002/qualification-export/<inventory-sha256>` and dispatch
`retain-qualification-evidence.yml` with that inventory digest, source and version.
The task-owned runner verifies every copied attachment and retains the export.

## Protected acceptance and promotion

Dispatch `release-qualification-acceptance.yml` with source/version, exact successful
stage run/attempt and evidence-retention run. Existing protected-environment
reviewers and main-branch restrictions remain. The workflow authenticates staged
bytes, corresponding source and evidence, then attests a
`hostwright.promotion-receipt.v3` naming the focused policy and all five reports.

`promote-release.yml` authenticates the exact stage and acceptance runs and receipt,
revalidates signed inventory and source, then publishes those accepted bytes
without rebuilding. Verify public asset hashes, publish the matching vendor-tap
formula and test public installation/upgrade. Official Homebrew acceptance is deferred.

Published releases, tags and evidence remain immutable. Failed/cancelled promotion
retains any created tag/assets for review; no automatic destructive rollback is allowed.
