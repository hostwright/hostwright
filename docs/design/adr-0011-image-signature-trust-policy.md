# ADR-0011: Exact Offline Image Signature Trust

Status: accepted for Phase 05 Gate 7

## Decision

Hostwright verifies image signatures only for exact `sha256` descriptor locks and only from a complete digest-verified Gate 6 OCI referrer graph. The accepted signature envelope is the standardized Sigstore bundle v0.3 `messageSignature` form. DSSE attestations are excluded because provenance belongs to Gate 10.

Manifest v2 may declare `imageTrust` version 1 with one to eight keyed or keyless authorities and a distinct-authority threshold. Keyed authorities use exact local public-key bytes. Keyless authorities require an exact HTTPS issuer, exact certificate identity, and an explicit Sigstore TrustedRoot JSON document. Authority validity and revocation timestamps are part of policy material.

Cosign v3.0.6 or newer within major version 3 is the verifier boundary. Hostwright verifies its executable identity, copies trust material into a private temporary directory, sends subject bytes on stdin, bounds execution and output, and removes only exact temporary files. Registry credentials never cross this boundary.

Verification state binds the descriptor digest, policy and trust-material digest, Gate 6 discovery and graph, cached subject-manifest bytes, verifier version, matched authorities, and threshold. Lifecycle confirmation binds trust-material content. Execution and recovery revalidate exact persisted evidence before effects.

An exception is allowed only through a strict bounded approval record bound to one project, service, descriptor digest, policy digest, approver, reason, approval time, expiry, and idempotency UUID. Exceptions are revocable, audited when used, and never authorize another digest or policy.

## Rejected alternatives

- Tags or mutation command output as trust state.
- Registry credentials in cosign argv or environment.
- Ambient system trust roots or identity regular expressions.
- DSSE, SBOM, vulnerability, or provenance interpretation in Gate 7.
- Broad force, all-content, prune, or cleanup behavior.
