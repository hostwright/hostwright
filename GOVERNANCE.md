# Governance

Hostwright uses maintainer-controlled decision making until the project has a public contributor base.

## Maintainer Authority

The maintainer owns release scope, dependency decisions, naming, runtime safety gates, public claims, release tags, and GitHub Releases.

Maintainer approval is required before any change that:

- adds a third-party dependency;
- changes licensing, naming, product positioning, or public compatibility claims;
- creates release tags, GitHub Releases, binary artifacts, installers, signing, notarization, SBOM, or provenance claims;
- expands runtime mutation, cleanup, lifecycle management, daemon mutation, or live proof scope;
- adds DNS, tunnel, cloud, CRI, Kubernetes, Docker API, external scheduler, multi-host, GUI, or website behavior;
- changes secret handling, redaction, policy bypass, state migration, ownership, confirmation, or destructive-action rules.

## Review Ownership

Risky areas require explicit maintainer review:

| Area | Required review focus |
| --- | --- |
| Runtime and lifecycle | `RuntimeAdapter` use, command policy, live proof scope, no broad mutation. |
| State and migrations | Explicit paths, migration checksums, lock/corrupt/future-version behavior, no hidden writes. |
| Cleanup and destructive actions | Ownership, dry-run classification, exact confirmation, no image/volume/unmanaged deletion. |
| Secrets and diagnostics | No raw secret persistence or output, redacted bundles, no credential sync or upload. |
| Policy and import | Fail-closed decisions, no silent override, no unsupported compatibility claims. |
| Team workflow | Local-only profile data, approval records, audit events, no cloud team service or silent safety-gate weakening. |
| Release and distribution | Source/binary artifact truth, tag discipline, signing/notarization/provenance wording. |
| Public docs and roadmap | Current support vs planned/research behavior, no website work in the core repo. |

Hostwright does not currently enforce CODEOWNERS. Adding enforced owners or branch-protection rules requires separate maintainer approval.

## Decision Records

Architecture or compatibility decisions that affect public behavior require a design record under `docs/design/`.

Decision records are required before:

- adding dependencies;
- expanding manifest semantics beyond the documented restricted subset;
- enabling live Keychain access;
- implementing plugin execution, provider integrations, tunnel/cloud/DNS behavior, accelerator behavior, external compatibility, multi-host behavior, launch agents, privileged helpers, or distribution artifacts;
- changing release strategy or support policy.

Research records may reject or defer work without adding implementation.

## Issue And Pull Request Flow

Issues are the unit of scoped roadmap work. Each issue should define goal, scope, non-goals, acceptance criteria, verification, safety boundaries, dependencies, risks, docs to update, and exit criteria.

Pull requests should:

- reference exactly the issue they close or support;
- keep implementation, tests, and required docs in one scoped change;
- list explicit out-of-scope behavior;
- run the full local gate when code changes;
- include targeted boundary scans for runtime/state/security-sensitive changes;
- avoid unrelated roadmap, website, marketing, or wording churn.

Docs-only research PRs still need a review pass for overclaims.

## Release Discipline

No release should claim production readiness until build, test, runtime, security, compatibility, and documentation gates are defined and passing.

Public releases use `v*` tags only. Internal `phase-*` tags are engineering checkpoints only. Release tags, GitHub Releases, binary artifacts, installers, signing, notarization, SBOM, provenance, Homebrew, or package-channel claims require explicit maintainer approval and matching release docs.

## Security And Support

Security reports should not be filed publicly when they include secrets, credentials, exploit details, private hostnames, private paths, or diagnostic bundles. Until a private disclosure channel is published, reporters should request a private maintainer contact first.

Hostwright has no support SLA, enterprise support program, cloud service, remote telemetry, or hosted diagnostics in the current core project.
