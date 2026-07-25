# ADR-0014: Exact Signed Image Build Provenance

Status: accepted for Phase 05 Gate 10

## Decision

Hostwright generates and verifies build provenance only for an exact `sha256` image manifest or index. A strict bounded build record supplies source, dependency and material digests, builder identity/version, build type, invocation UUID, a digest-only command model, allowlisted environment-variable names and network policy, timestamps, output, and an explicit reproducibility result. HTTPS and URN resource identities are accepted only without credentials, query strings, fragments, host filesystem paths, traversal, or conflicting digests.

Generation emits an in-toto Statement v1 using the SLSA provenance v1 predicate and signs that exact payload in a DSSE Ed25519 envelope. The private key is resolved only from an exact typed secret-provider reference at the signing boundary. Key bytes and the reference itself never enter argv, state, output, diagnostics, the statement, or OCI annotations. A generated OCI artifact graph is reloaded, extracted, and cryptographically verified before success; generation output is never treated as state.

Manifest v2 `imageProvenance` version 1 declares whether evidence is optional or required, accepted builders and build types, signer public keys and authority windows, maximum age, and whether reproducibility proof is required. Verification accepts one exact provenance referrer from a complete digest-verified Gate 6 graph and checks its OCI subject, DSSE payload type, statement and envelope digests, Ed25519 signature, image subject, builder, build type, material set, timestamps, signer authority, freshness, and reproducibility disposition.

Schema v13 stores immutable evidence bound to the project/service, image descriptor, policy and signer-material hashes, Gate 6 discovery and graph, provenance referrer and envelope, statement and signature proof, builder/build type/materials, verification time, and durable operation group. Status, lifecycle execution, and recovery reload the exact graph and current policy material before effects. Cancellation leaves a fenced interrupted group; resume requires the exact plan, and generation additionally requires the same typed signing-reference digest. Exact referrer cleanup refuses any immutable provenance reference.

The versioned CLI and one-shot Control API share the same implementation. Gate 10 does not clone source, execute builds, establish remote-builder identity, infer reproducibility, upload implicitly, use registry credentials for signing, delete registry content on rollback, implement leases or garbage collection, or claim source-build integrity beyond the verified signed statement.

## Rejected alternatives

- Treating build stdout, native argv, mutable tags, archive filenames, generated JSON, or state rows as proof.
- Persisting secret references, key bytes, environment values, host paths, or undeclared build metadata.
- Accepting unsigned statements, arbitrary predicate types, multiple ambiguous subjects, or weakly bound signer policy.
- Inferring reproducibility from matching tags or operator assertion without an exact comparison digest.
- Implicit registry publication, broad rollback deletion, or Gate 11 content-pressure behavior during provenance generation.
