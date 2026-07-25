# ADR 0010: OCI Referrer Transport and Retention

Status: Accepted for Phase 05 Gate 6

## Decision

Hostwright implements OCI referrers as a bounded, content-addressed registry graph. It stores and transports opaque OCI manifests and blobs while preserving exact subject and descriptor digests. Gate 6 does not interpret signatures, attestations, SBOMs, or provenance and does not make a trust decision.

The implementation follows OCI Distribution 1.1 and OCI Image 1.1:

- discovery uses `/v2/<repository>/referrers/<subject-digest>`;
- a `404` falls back to the OCI referrers tag schema only when the truncated tag remains an injective content identity; SHA-512 and other non-injective fallback cases report an explicit unsupported capability instead of querying or mutating a colliding tag;
- pagination follows only same-origin `rel="next"` links for the same repository, subject, and filter;
- publishing verifies a manifest's calculated digest and exact `subject.digest`;
- a missing `OCI-Subject` response requires a conditional, conflict-detecting referrers-tag update;
- every fetched manifest and blob is rehashed before it is accepted or cached.

The public surface is `hostwright registry referrers` with versioned structured results and one-shot Control API parity. Supported operations are discovery, fetch, publish, copy, retain, release, status, and prune. Registry credentials continue to come only from Hostwright Keychain or guarded Docker/OCI credential stores.

## Bounds

- 16 discovery pages;
- 512 referrer descriptors;
- 1,024 total graph descriptors;
- graph depth 8;
- 8 MiB per manifest or blob;
- 64 MiB total fetched content;
- 128 annotations per descriptor, with bounded keys and values;
- one registry repository and one exact subject digest per operation.

Cycles, duplicate descriptors with conflicting metadata, repeated pagination links, cross-origin locations, digest/size mismatches, unsupported media types, and limit exhaustion fail closed.

## Durable State

State schema v9 records:

- the registry, repository, subject digest, discovery mode, filter behavior, ETag, completion, and graph digest;
- exact referrer descriptors and their verified subject binding;
- content-addressed cached manifests and blobs;
- Hostwright publication ownership proof;
- narrow referrer retention leases;
- operation intent, checkpoints, compensation limits, and post-operation verification through the existing fenced operation-group ledger.

Cached payloads are Hostwright-owned. A cache prune removes only payloads that have no descriptor/graph reference and no active referrer retention lease. A remote prune addresses only an exact Hostwright-published manifest digest, re-verifies ownership and subject binding, and never deletes blobs or performs broad registry cleanup.

Gate 11 remains responsible for general image/content leases, cache-pressure policy, and garbage collection. Gate 6 implements only the narrow retention required to prevent a known referrer graph from being removed while it is copied, inspected, or consumed by later supply-chain gates.

## Recovery and Cancellation

Mutation intent is durable before the first registry effect. Upload-session locations are accepted only when they are same-origin and remain below the exact repository upload path. Cancellation attempts exact upload-session cancellation. Successfully uploaded content-addressed blobs are not deleted during rollback because another manifest may reference them. A manifest or fallback-index effect that cannot be safely compensated remains an explicit resumable operation with exact verification evidence.

Recovery repeats only idempotent digest-addressed operations, revalidates registry capability and cached content, and observes registry state after every mutation. Mutation response text is never treated as state.

## Compatibility

Capability results distinguish native referrers, conditional tag fallback, read-only fallback, offline cache, and unsupported/malformed registry behavior. Server-side artifact filtering is reported separately from Hostwright's bounded client-side filter. Empty fallback state is explicit and is not reported as native API support.

State v8 upgrades transactionally to v9. Newer schemas are refused. Control API v2 gains an additive `registry` operation and bounded referrer fields; unknown or cross-operation fields remain errors.

## Alternatives Rejected

- Shelling out to `oras`, `docker`, or `container`: credentials and mutation semantics would cross an argv/subprocess boundary and post-operation state would be provider-specific.
- Treating the referrers response as proof of subject binding: the registry index is discovery data; Hostwright verifies each fetched manifest's subject itself.
- Unconditional fallback-tag writes: concurrent writers can lose descriptors.
- Broad manifest/blob deletion or native registry prune: ownership and reachability cannot be proven safely.
- Implementing signature, SBOM, vulnerability, or provenance semantics here: those belong to Gates 7–10.

## Verification

Gate 6 requires unit contracts, state migration, local transport integration, cancellation/recovery, security review, malformed-graph resilience, OCI native/fallback interoperability, CLI/Control parity, and exact-cleanup tests before its capability or documentation can be marked complete.

Primary specifications:

- <https://github.com/opencontainers/distribution-spec/blob/main/spec.md>
- <https://github.com/opencontainers/image-spec/blob/main/manifest.md>
- <https://github.com/opencontainers/image-spec/blob/main/descriptor.md>
