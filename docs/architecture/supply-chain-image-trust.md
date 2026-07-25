# Supply Chain And Image Trust Boundary

Status: Phase 05 Gates 7–10 exact image-signature, SBOM, vulnerability, and build-provenance boundary.

## Implemented

Hostwright supports digest-pinned image references and optional offline signature, SBOM, vulnerability, and build-provenance policies. The provenance policy names exact builders, build types, signers, freshness, and reproducibility requirements:

```yaml
imagePolicy: require-digest
imageTrust:
  version: 1
  threshold: 1
  authorities:
    - id: release
      type: keyed
      publicKey: /absolute/path/release.pub
imageProvenance:
  version: 1
  requirement: required
  builderIDs:
    - urn:hostwright:builder:apple-container
  buildTypes:
    - https://hostwright.dev/build-types/apple-container/v1
  signers:
    - id: release-builder
      publicKey: /absolute/path/provenance.pub
  maximumAgeSeconds: 604800
  requireReproducible: true
```

When set, every service `image` must include `@sha256:<64 lowercase hex characters>`. The default remains `allow-tags` so existing alpha manifests keep validating unless the operator opts into digest-required validation.

Manifest validation and lifecycle planning perform no registry access. Signature, SBOM, vulnerability, and provenance verification are explicit offline steps over exact cached Gate 6 evidence. Lifecycle mutation then reloads the exact graph and current policy material and requires every declared policy to pass before provider effects.

## Research Findings

OCI separates mutable tags from content identifiers. The OCI Distribution Specification describes a tag as a human-readable pointer to a manifest and a digest as a cryptographic content identifier. The OCI Image Specification defines digest grammar and states that SHA-256 encoded values use 64 lowercase hex characters.

Sigstore/cosign verification is implemented for standardized bundle v0.3 message signatures, exact keyed or keyless authorities, explicit trusted roots, distinct-authority thresholds, and bounded failure reporting.

SPDX and CycloneDX are SBOM standards/data models, not vulnerability scanners. Hostwright generates or ingests only the bounded formats and exact image binding implemented in Gate 8.

In-toto Statement v1 provides the exact subject/predicate envelope, SLSA provenance v1 supplies the build-definition and run-details predicate, and DSSE signs a typed payload. Gate 10 emits and verifies that bounded combination with Ed25519, but it does not infer an external builder identity, execute a build, or claim facts absent from the supplied build record.

OCI 1.1 subject/referrer relationships transport the signed envelope as an exact image-bound artifact. The verified Gate 6 graph remains the transport authority; generation output and database rows are never accepted as current registry state by themselves.

References:

- OCI Distribution Specification: https://github.com/opencontainers/distribution-spec/blob/main/spec.md
- OCI Image Specification descriptor digest rules: https://github.com/opencontainers/image-spec/blob/main/descriptor.md
- Sigstore/cosign container signing: https://docs.sigstore.dev/cosign/signing/signing_with_containers/
- SPDX: https://spdx.dev/
- CycloneDX specification overview: https://cyclonedx.org/specification/overview/
- in-toto Statement v1: https://github.com/in-toto/attestation/blob/main/spec/v1/statement.md
- DSSE protocol: https://github.com/secure-systems-lab/dsse/blob/master/protocol.md
- SLSA provenance v1.0: https://slsa.dev/spec/v1.0/provenance

## Decisions

| Capability | Phase 25 decision | Reason |
| --- | --- | --- |
| Digest-pinned image references | Implement narrow local policy | Deterministic, offline, and useful before future policy work. |
| Mutable tag bans | Implement only when `imagePolicy: require-digest` is explicit | Avoids breaking existing alpha manifests by default. |
| Signature verification | Implement exact offline Gate 7 policy | Exact digest, Gate 6 evidence, trust material, identity, threshold, and verifier evidence are persisted and revalidated. |
| SBOM generation or validation | Implement bounded Gate 8 policy | Exact SPDX/CycloneDX subjects, documents, normalized components, policy, graph, and referrers are persisted and revalidated. |
| Vulnerability scanning | Accept signed reports only in Gate 9 | Hostwright evaluates exact signed report evidence and never runs or updates a scanner/database. |
| Build provenance | Implement bounded Gate 10 generation and verification | Exact image, source/material digests, builder/build type, invocation model, timestamps, signer material, graph, and policy are persisted and revalidated. |
| Source-build integrity automation | Defer | Gate 10 does not clone source, execute builds, establish remote builder authority, or infer reproducibility. |
| Registry mutation or automatic pulls during lifecycle | Reject for this phase | Gate 6 publication remains explicit; lifecycle authorization uses verified cached evidence and never performs implicit registry effects. |

## Boundaries

- No implicit registry calls during lifecycle planning or execution.
- No implicit image pulls.
- No registry credentials cross signature, SBOM, vulnerability, or provenance verification boundaries.
- No signing key in argv, state, output, diagnostics, build records, OCI annotations, or provenance payloads.
- No native build argv, environment values, host paths, or undeclared metadata in provenance.
- No scanner/database execution, source checkout, build execution, or remote-builder trust service.
- No claim that digest pinning alone proves an image is safe.
- No broad image or artifact cleanup; exact cleanup refuses immutable signature, SBOM, vulnerability, or provenance references.
