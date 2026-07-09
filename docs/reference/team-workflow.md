# Team Workflow

Status: Phase 34 local profile and approval model.

Hostwright does not provide a cloud team service, central remote control, hosted audit log, user tracking, enterprise support workflow, or organization account system.

Phase 34 adds local data models and policy decisions for team workflow review:

- team policy profile identity, version, display name, and explicit opt-in;
- required safety gates;
- local policy overrides;
- local approval records;
- audit events through the existing explicit-path event ledger.

## Local Team Profiles

A team profile is local data. It is not fetched from a server and is not applied silently.

Required profile properties:

- stable identifier;
- profile version `1`;
- display name;
- explicit opt-in;
- declared required gates;
- optional stricter policy defaults;
- optional local approval records for reviewed exceptions.

Required gates:

- `runtimeAdapter`
- `explicitStatePath`
- `localPolicy`
- `redaction`
- `auditTrail`
- `planConfirmation`
- `cleanupConfirmation`
- `ownershipChecks`
- `localOnlyNoCloud`
- `noTelemetryUpload`

Missing gates are blockers. Team defaults cannot remove required Hostwright gates.

## Approval Records

Approval records are local review records. They document who reviewed an override, what scope they reviewed, and when the review was recorded.

Approval records do not bypass hard-coded Hostwright safety gates. Plan hashes, cleanup tokens, ownership checks, redaction, explicit state paths, local-only diagnostics, and `RuntimeAdapter` remain mandatory.

## Override Policy

Stricter team defaults can be declared as policy data, such as requiring digest-pinned images or manifest review.

Overrides that weaken required gates require an approved local review record before the profile is accepted as reviewed data.

Some overrides are always blocked in current core scope:

- broad bind address allowance;
- plan confirmation bypass;
- cleanup confirmation bypass;
- ownership-check bypass;
- default state path;
- telemetry upload;
- runtime mutation expansion.

## Audit Events

Team workflow audit records use the existing event ledger and explicit state database path. Suggested event types:

- `team.approval.recorded`
- `team.policy.override.reviewed`
- `team.profile.selected`

Event payloads are redacted before persistence. Audit events are local records, not uploads.

## Shared Machines

On shared Macs, operators should treat manifests, state databases, diagnostic bundles, and approval records as local files with local filesystem permissions. Hostwright does not manage macOS users, groups, ACLs, keychain access groups, shared secret stores, or device-management policy.

Teams should keep state database paths explicit and review file permissions outside Hostwright before using a shared machine.

## Non-Goals

- Cloud team service.
- Central remote control.
- Hosted audit log.
- User tracking.
- Enterprise support workflow.
- Organization account model.
- Remote policy distribution.
- Policy bypass.
- Hidden default state paths.
- macOS user, group, ACL, or MDM management.
