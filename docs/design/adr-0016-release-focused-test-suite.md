# ADR 0016: Keep tests for the supported local release

Status: accepted by the maintainer on 2026-09-22.

## Decision

The automated suite protects the single-Mac CLI, authenticated Control API, native
desktop, Compose conversion, and their required local runtime and release boundaries.
This supersedes only ADR 0015's requirement to preserve deep development tests for
deferred features. Product behavior, public interfaces, release scope, and historical
evidence are unchanged.

Retire obsolete phase-specific qualification tests and deep tests of deferred
clustering, accelerators, Kubernetes/pod sandboxes, Docker-client compatibility,
and scheduler optimization/preemption. Keep capability availability, supported
packaging, existing unsupported-request refusals, and absence-of-effects coverage.
Keep shared authentication, ownership, state migration, and other local-product
safety tests even when their source file also covers a deferred feature.

Delete tests of source spelling, helper names, arbitrary prose, completed release
ceremonies, and language/library behavior. Centralized package/process-boundary
lint owns architectural prohibitions; documentation validation owns current
contract consistency, links, executable examples, and immutable history.

Distinct parser, persistence, transport, and end-to-end boundaries remain distinct
coverage. Consolidated cases use independent state and identifiable failures.
Delete duplicates only when a retained case protects the same boundary and outcome.

## Verification and traceability

Every removed identifier maps to a retained behavior, an executable replacement,
or a requirement retired by this decision. Preserve current-product failures rather
than deleting their tests. Keep schema-v24 migration continuity, local scheduling's
independent safety oracle, and durable distribution lifecycle sentinels.

Deferred code remains available as development code with reduced regression
coverage. Reintroducing it into the supported product requires restoring suitable
tests and current-source qualification. Historical evidence cannot qualify changed
source, and is never rewritten to match new fingerprints.

Local example checks consume tracked working-tree files or an explicit source
snapshot. Untracked developer material is not a release corpus. Qualification still
rejects dirty or incomplete formal evidence; excluding unrelated local files from
ordinary documentation tests does not weaken that requirement.
