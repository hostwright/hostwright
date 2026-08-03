# Secure Workload Profiles

Workload Profile v1 is the reusable, state-backed security envelope for daemon-controlled lifecycle work. It covers filesystem access, network mode and origins, CPU/memory/process limits, runtime identity, secret references, image requirements, runtime options, host access, observability, accelerators, syscalls, and extension grants. The canonical shape is frozen in [`phase09-profile-v1.json`](../../contracts/v0.0.2/phase09-profile-v1.json).

Profiles are stored in schema v20 as canonical JSON with a verified SHA-256 digest and optimistic generation. Reads re-decode and re-hash the document. State integrity repeats those checks and rejects a missing parent, inheritance cycle, depth above 32, noncanonical JSON, or digest mismatch. Profile creation/update is transactional; a rejected write leaves the prior generation unchanged. Migration rollback restores the verified pre-v20 backup instead of down-migrating.

## Inheritance and weakening

A profile has at most one parent. Optional `resources` and `identity` blocks inherit when omitted; every other block is explicit. A child can narrow allowlists, lower resource ceilings, add denied runtime options or syscalls, require stronger image/root/filesystem restrictions, disable host/observability capabilities, and reduce extension grants. Widening any inherited or current constraint requires both:

- an RBAC `approve` decision for resource `profile` and operation `profile.weaken`; and
- a future-expiring approval bound to the actor, profile ID, current/base profile digest, and candidate digest.

Approval binds the current effective inheritance hash and the proposed effective inheritance hash, not only either raw row digest. Changing parent content, effective content, actor, base generation, or expiry therefore invalidates approval. An approval supplied for a non-weakening change is rejected rather than ignored.

## Control and admission

The authenticated Control API exposes `profile.list`, `profile.get`, `profile.resolve`, `profile.preview`, `profile.drift`, `profile.create`, `profile.update`, and `profile.delete`. Bodies reject unknown keys. Reads require `profile` get/list authority; mutations require create/update/delete authority. A parent with children cannot be deleted.

A lifecycle request selects `workloadProfileID`. Admission resolves its inheritance chain, injects the canonical effective `profileHash`, includes that hash in the deterministic intent plan, and performs the second RBAC pass against the effective hash. A caller-supplied mismatched hash is a mutation conflict. Disabled profile observability denies its matching logs, metrics, or traces operation. The bootstrap adapter carries the exact ID/hash pair to lifecycle preflight; the pair is not an authorization or weakening token.

Requests without `workloadProfileID` retain legacy lifecycle behavior. No profile is discovered or silently selected.

## Runtime enforcement and capability gaps

Lifecycle preflight re-resolves the profile from the selected schema-v20 database and compares the admission-bound hash before provider mutation. It checks the selected provider, CPU/memory ceilings, user/group/root policy, image digest, read-only root, host-root mounts, host access, isolated networking, secret-reference allowlists, and the exact enforceable runtime options `init`, `rosetta`, `shared-memory`, and `virtualization`.

Fields the current Apple container provider cannot enforce exactly—filesystem path allowlists, network-origin allowlists, process-count ceilings, runtime image-signature enforcement, accelerators, syscall policy, and extension grants before their Gate 10 capability boundary exists—produce sorted capability-gap identifiers and fail before mutation. Brokered networking requires the provider's implemented network capability. There is no permissive fallback.

## Drift, recovery, and troubleshooting

`profile.resolve` returns inheritance IDs, source digests, the materialized profile, and effective SHA-256. `profile.drift` compares an observed hash and sorted observed reasons with that authority. Restart/reopen recomputes the same effective hash from canonical state; a provider disappearing or changing capabilities is reported as a gap and blocks the next mutation.

For a rejection:

1. Resolve the profile and compare its effective hash with the admitted hash.
2. Inspect the sorted `providerMismatch`, `unsupportedCapabilities`, or `workloadViolation` reasons.
3. Update the workload or provider so every field is enforceable; do not remove the profile or broaden a child as a workaround.
4. If deliberate weakening is required, obtain a new exact expiring approval after reviewing the candidate digest.
5. If profile state fails integrity, preserve the database and restore its verified pre-migration backup. Do not edit rows or down-migrate.

Profile operations create no external resource. Failed preflight and cancellation before provider mutation require no runtime cleanup. Later runtime cleanup remains restricted to resources proven by the Hostwright ownership ledger.
