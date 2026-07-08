# Supply Chain And Image Trust Boundary

Status: Phase 25 local policy and research boundary.

## Implemented

Hostwright supports one local manifest policy:

```yaml
imagePolicy: require-digest
```

When set, every service `image` must include `@sha256:<64 lowercase hex characters>`. The default remains `allow-tags` so existing alpha manifests keep validating unless the operator opts into digest-required validation.

This policy runs before planning or mutation and does not perform network access. It is a deterministic manifest validation rule, not registry trust verification.

## Research Findings

OCI separates mutable tags from content identifiers. The OCI Distribution Specification describes a tag as a human-readable pointer to a manifest and a digest as a cryptographic content identifier. The OCI Image Specification defines digest grammar and states that SHA-256 encoded values use 64 lowercase hex characters.

Sigstore/cosign image signing operates around digest-addressed images and attached signatures or attestations. Adding that capability would require resolver, referrer, key identity, trust-root, policy, and failure-reporting design.

SPDX and CycloneDX are SBOM standards/data models, not automatic Hostwright scanners. Supporting SBOMs would require separate decisions for accepting SBOM input, producing SBOMs, validating them, and turning them into policy results.

SLSA provenance depends on build-platform attestations with a trusted builder identity and downstream verification model. Hostwright cannot claim provenance without producing or verifying those attestations.

References:

- OCI Distribution Specification: https://github.com/opencontainers/distribution-spec/blob/main/spec.md
- OCI Image Specification descriptor digest rules: https://github.com/opencontainers/image-spec/blob/main/descriptor.md
- Sigstore/cosign container signing: https://docs.sigstore.dev/cosign/signing/signing_with_containers/
- SPDX: https://spdx.dev/
- CycloneDX specification overview: https://cyclonedx.org/specification/overview/
- SLSA provenance v1.0: https://slsa.dev/spec/v1.0/provenance

## Decisions

| Capability | Phase 25 decision | Reason |
| --- | --- | --- |
| Digest-pinned image references | Implement narrow local policy | Deterministic, offline, and useful before future policy work. |
| Mutable tag bans | Implement only when `imagePolicy: require-digest` is explicit | Avoids breaking existing alpha manifests by default. |
| Signature verification | Defer | Requires trust roots, resolver behavior, identity policy, and referrer handling. |
| SBOM generation or validation | Defer | Requires format, storage, generator/importer, and policy design. |
| Vulnerability scanning | Defer | Requires scanner dependency, vulnerability database source, offline/online policy, and result surface. |
| Dependency provenance and source-build integrity | Defer | Requires build-system attestations and verification workflow. |
| Registry mutation or automatic pulls | Reject for this phase | Runtime image acquisition remains outside Hostwright's current mutation surface. |

## Boundaries

- No registry calls.
- No image pulls.
- No registry credentials.
- No scanner, signing, SBOM, or provenance dependency.
- No claim that digest pinning alone proves an image is safe.
- No image replacement, image cleanup, or broad lifecycle expansion.
