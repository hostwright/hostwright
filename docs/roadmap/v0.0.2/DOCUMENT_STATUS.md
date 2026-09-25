# Documentation sources

Use these records for current behavior and release scope:

- `README.md` and `docs/reference/`: setup, commands, compatibility, and operation.
- `docs/roadmap/v0.0.2/IMPLEMENTATION_PLAN.md`: accepted release scope and remaining gates.
- `docs/roadmap/v0.0.2/issues.json`: issue identities, hierarchy, ownership, and dispositions.
- `Sources/HostwrightCore/HostwrightIdentity.swift`, `ContractVersions.swift`, and `CapabilityCatalog.swift`: executable version and capability declarations.
- `schemas/` and `contracts/v0.0.2/`: machine-readable contracts and fixtures.
- `docs/release/RELEASE_PROCESS.md`: qualification, approval, and publication.
- `docs/design/`: architecture and scope decisions, including ADRs 0015 and 0016.

Resolve disagreements against the implementation and its tests before changing public claims. The website must match these references; see [website and documentation](../../architecture/documentation-site-public-education.md).

## Retained history

Superseded plans, implementation diaries, and session notes are available in Git history. They do not define current support. The test-suite disposition and deletion records under `docs/devlog/` retain the audit for ADR 0016.

`docs/release/IMMUTABLE_RELEASES.json` protects the exact bytes of historical release notes. Preserve those files and published evidence. Current documentation may explain their status without changing the original record.

## Checks

`check-current-truth.py` validates versions, schema and evidence-class consistency, examples, and immutable hashes. `roadmap-governance.py` validates issue relationships and closure evidence. `check-docs.sh` checks links and executable manifest examples. Release qualification runs the documentation validators against a snapshot of the exact source commit.
