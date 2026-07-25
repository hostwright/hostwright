# ADR-0012: Exact Image SBOM Generation And Binding

Status: accepted for Phase 05 Gate 8

## Decision

Hostwright accepts image SBOMs only for exact `sha256` image descriptor locks and only as SPDX 2.3 JSON or CycloneDX 1.5/1.6 JSON. Parsing is strict and bounded. Every accepted document must contain the exact image digest, normalize to a deterministic component set, and arrive through a complete digest-verified Gate 6 OCI referrer graph.

Manifest v2 may declare `imageSBOM` version 1, an `optional` or `required` policy, and one or both supported formats. The canonical policy digest participates in lifecycle confirmation. A required policy must have current immutable evidence for every declared format before runtime effects; persisted recovery repeats graph and document verification.

Generation reads one safely owned, non-symlink OCI image-layout tar archive. Hostwright validates tar structure, descriptors, configuration, manifests, and layers, then inspects only bounded Alpine and Debian package databases through the secure subprocess boundary. Generated SPDX 2.3 and CycloneDX 1.6 artifacts use deterministic content addressing and a digest-protected OCI subject.

Schema v11 binds project, service, image descriptor, policy, format, document digest and media type, Gate 6 discovery and graph, SBOM referrer, normalized components, operation group, and optional provenance descriptor/referrer identities. Provenance identities are references only; Gate 8 does not generate or verify provenance.

Generate, ingest, and export persist non-secret bounded intent before effects. Cancellation leaves an interrupted group, and resume requires the exact confirmation hash. Export creates one private file without overwrite, verifies its digest after persistence, adopts only the exact safe file during recovery, and removes only a file created by that failed attempt.

CLI and one-shot Control API operations share the same implementation. Neither surface accepts registry credentials. Query, export, lifecycle, and recovery re-observe verified OCI content instead of treating mutation output or state rows as current evidence.

## Rejected alternatives

- Tags, mutation stdout, or unverified state rows as SBOM state.
- Unbounded filesystem walking or package-manager execution inside an image.
- Credentials in argv, documents, durable intent, diagnostics, or provenance.
- Overwriting export destinations or broad temporary/cache cleanup.
- Vulnerability decisions, signature policy, provenance verification, leases, pressure eviction, or garbage collection in Gate 8.
