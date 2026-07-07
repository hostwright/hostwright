# Phase 19: Cleanup Classification Maturity

## What changed

- `hostwright cleanup --dry-run` reports ownership-backed and observed-only cleanup assessments as eligible, ambiguous, stale, running, unknown, blocked, or never-delete.
- Confirmed cleanup executes only eligible exact Hostwright-owned created/stopped/exited containers through `RuntimeAdapter`.
- Apply-created ownership records persist the observed runtime adapter name so cleanup can block adapter mismatches.
- Cleanup confirmation tokens include eligible candidate identity, lifecycle, runtime adapter, and resource identifier.
- Runtime delete success followed by state persistence failure reports state unavailable while keeping the completed deletion visible in stdout.

## Assumptions

- Ownership records remain the cleanup authority.
- Observed containers without ownership records are reported for operator awareness but never become cleanup candidates.
- Missing or ambiguous live observation is a refusal condition, not a reason to infer deletion.
- Legacy ownership rows that use the previous runtime-adapter sentinel are upgraded by the state migration before cleanup classification.

## Rejected paths

- No image cleanup.
- No volume cleanup.
- No unmanaged deletion.
- No wildcard deletion.
- No force flag.
- No automatic background cleanup.
