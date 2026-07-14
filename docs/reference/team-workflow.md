# Team Workflow

Status: Phase 34 local operational profile and approval workflow.

Hostwright loads team policy only from an explicit `--team-profile <path>`. It does not search for a profile, download policy, or apply organization defaults silently. Profile-aware runtime mutation also requires an explicit `--approval-record <path>` bound to the current operation.

## Team Profile Format

Profiles are strict JSON objects. Unknown or missing fields, unsupported enum values, duplicate gates or requirements, unsupported versions, invalid identifiers, and `optIn: false` fail closed with `HW-TEAM-001`.

```json
{
  "kind": "HostwrightTeamProfile",
  "apiVersion": 1,
  "identifier": "dev.hostwright.team.local",
  "displayName": "Local Maintainers",
  "optIn": true,
  "requiredGates": [
    "runtimeAdapter",
    "explicitStatePath",
    "localPolicy",
    "redaction",
    "auditTrail",
    "planConfirmation",
    "cleanupConfirmation",
    "ownershipChecks",
    "localOnlyNoCloud",
    "noTelemetryUpload"
  ],
  "requirements": [
    "requireImageDigest",
    "requireManifestReview"
  ]
}
```

Every required gate must appear exactly once. Operational profiles can only add these stricter requirements:

- `requireImageDigest`: all service images must use a valid `@sha256:<64 lowercase hex>` content identity, even when the manifest says or defaults to `allow-tags`.
- `requireManifestReview`: records that the team requires reviewed manifests. All profile-aware apply and confirmed cleanup operations require an exact approval record regardless of the declared requirement list.

There is no weakening override format. A profile cannot permit broad bind addresses, privileged ports, hidden state paths, confirmation bypass, ownership bypass, telemetry upload, expanded runtime mutation, or any other relaxation of core policy.

## Approval Record Format

Approval records are strict JSON objects. They authorize one reviewed `apply` or `cleanup` operation; they do not change policy.

```json
{
  "kind": "HostwrightApprovalRecord",
  "apiVersion": 1,
  "id": "approval-2026-07-12-001",
  "reviewer": "local-maintainer",
  "decision": "approved",
  "scope": "apply",
  "recordedAt": "2026-07-12T12:00:00Z",
  "profileHash": "<64 lowercase hex characters>",
  "manifestHash": "<64 lowercase hex characters>",
  "planHash": "<exact plan hash>"
}
```

Only `decision: approved` is accepted for mutation. `scope` must be `apply` or `cleanup`. For cleanup, `planHash` contains the exact token printed by the profile-aware dry run. Wrong scope or stale profile, manifest, plan, or cleanup bindings fail with `HW-TEAM-003` before runtime mutation.

## Hash Contract

- `profileHash`: SHA-256 of the decoded profile re-encoded as sorted-key canonical JSON.
- `manifestHash`: SHA-256 of the exact manifest text read by the command.
- `planHash`: the existing deterministic reconciliation plan hash, or the profile-bound cleanup token.
- `approvalHash`: SHA-256 of the decoded approval record re-encoded as sorted-key canonical JSON. It is computed by Hostwright and does not appear inside the approval file.

Formatting-only changes to a profile or approval do not change its canonical hash. Any manifest byte change invalidates its approval binding. A changed plan, observed state, cleanup candidate set, profile, scope, or approval requires a new approval record.

## Command Flow

Read-only validation and planning:

```bash
hostwright validate hostwright.yaml --team-profile team-profile.json
hostwright plan hostwright.yaml --team-profile team-profile.json --output json
hostwright import-stack compose.yaml --team-profile team-profile.json --output json
```

Profile-aware plan output includes `profileHash`, `manifestHash`, `planHash`, and `approvalRequiredForMutation`. Text import keeps converted manifest stdout parseable and reports profile metadata on stderr; JSON import includes a `teamPolicy` object.

Confirmed apply:

```bash
hostwright apply hostwright.yaml \
  --confirm-plan <plan-hash> \
  --team-profile team-profile.json \
  --approval-record approval.json
```

Confirmed cleanup starts with a profile-aware dry run, then uses a cleanup-scoped approval bound to its exact token:

```bash
hostwright cleanup hostwright.yaml \
  --dry-run \
  --team-profile team-profile.json

hostwright cleanup hostwright.yaml \
  --confirm-cleanup <cleanup-token> \
  --team-profile team-profile.json \
  --approval-record cleanup-approval.json
```

`--approval-record` without `--team-profile` is rejected. Apply requires an approval whenever a profile is selected. Cleanup dry-run rejects approval input because review must bind the token produced by that dry run. These examples use the secure default state; add `--state-db <absolute-path>` only when an explicit override is required.

## Confirmation And Audit

Profile-aware mutation carries the profile, manifest, plan, and approval hashes in `RuntimeMutationConfirmation`. Existing plan/token confirmation and exact ownership checks still run independently.

The selected SQLite state path records the same binding in redacted append-only operation/event payloads. Events include:

- `team.profile.selected` for profile-aware cleanup dry-run;
- `team.approval.recorded` before profile-aware apply or cleanup mutation;
- the existing apply/cleanup success or failure events with the same binding metadata.

Approval id, reviewer, timestamp, scope, and hashes are redacted before persistence. An audit write failure before mutation blocks the mutation. Approval records never bypass `RuntimeAdapter`, exact resource identifiers, ownership, confirmation, redaction, secure selected-state policy, local-only diagnostics, or cleanup eligibility.

## Shared Machines

Profiles, approvals, manifests, and state databases are ordinary local files. Operators must set appropriate filesystem ownership and permissions outside Hostwright. Hostwright does not manage macOS users, groups, ACLs, Keychain access groups, shared secret stores, or device-management policy.

## Current Sequenced Limitations

- Cloud team service or organization account model.
- Central remote control or hosted audit log.
- Remote policy distribution or silent defaults.
- Policy weakening or approval-based safety bypass.
- User tracking or enterprise support workflow.
- macOS account, ACL, Keychain access-group, or MDM management.
- Shared-secret distribution.
