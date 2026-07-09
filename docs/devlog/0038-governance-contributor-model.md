# Phase 38: Governance And Contributor Model

Phase 38 made governance explicit without adding product behavior.

## What changed

- Expanded `GOVERNANCE.md` with maintainer authority, risky-area review ownership, decision-record triggers, issue/PR flow, release discipline, and support boundaries.
- Expanded `CONTRIBUTING.md` with full local gates, issue scope rules, review triggers, and fixture/local-material rules.
- Expanded `SECURITY.md` with private-report guidance and security review triggers.
- Updated the issue and pull request templates so contributors see the same verification and safety expectations before review.
- Added release-governance, requirements, acceptance, traceability, limitations, security/safety, and build-status records.
- Added a core docs guard for governance and unsupported-current-support claims.

## Safety boundaries

- No CODEOWNERS enforcement.
- No branch protection changes.
- No new maintainers.
- No product code.
- No runtime mutation.
- No dependency changes.
- No website implementation.
- No GUI code.
- No support SLA, hosted diagnostics, telemetry upload, or cloud service.
- No release tags or GitHub Releases.
- No binary artifacts, signing, notarization, SBOM, or provenance claims.
