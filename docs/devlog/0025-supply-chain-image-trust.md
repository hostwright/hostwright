# Phase 25: Supply Chain And Image Trust

Phase 25 adds a narrow local image-reference policy and records the supply-chain trust boundary.

What changed:

- Added optional manifest `imagePolicy: allow-tags|require-digest`.
- Kept `allow-tags` as the default for existing alpha manifests.
- Added local validation for `@sha256:<64 lowercase hex characters>` image references.
- Made `require-digest` reject mutable tag-only images before planning or mutation.
- Added manifest/schema tests for accepted and rejected image policy shapes.
- Documented why signatures, SBOMs, vulnerability scanning, provenance, registry mutation, and automatic pulls remain deferred or rejected for this phase.

What did not change:

- No registry lookup.
- No image pull.
- No signature verification.
- No SBOM generation or validation.
- No vulnerability scanner.
- No provenance claim.
- No image replacement, image cleanup, or broad lifecycle work.
