# Contributing

Hostwright changes should be small, testable, and honest about runtime boundaries.

## Ground Rules

- Keep the first supported release local and single-host.
- Use Swift and Swift Package Manager unless a design record approves another tool.
- Keep dependencies minimal.
- Add or update tests for changed behavior.
- Do not add runtime mutation before dry-run planning and adapter boundaries exist.
- Do not add destructive behavior without explicit confirmation design.
- Do not add unsupported compatibility claims.
- Do not add release artifacts, tags, GitHub Releases, website implementation, GUI code, cloud services, tunnels, DNS integration, Kubernetes/CRI/Docker API behavior, multi-host mutation, or accelerator support without a dedicated approved issue.
- Keep docs changes tied to changed behavior, release truth, or the scoped research issue. Avoid broad roadmap wording churn.

## Local Checks

```bash
swift build
swift test list || swift test --list-tests
swift test
scripts/grep-orchard.sh .
scripts/test.sh
scripts/lint.sh
```

## Runtime Boundaries

All runtime behavior must go through `RuntimeAdapter`. CLI, daemon, state, reconciler, and health modules must not shell out directly to Apple container or any other runtime.

SQLite access must stay inside `HostwrightState`. State writes require explicit state database paths; no hidden default user database path should be introduced.

## Issue Scope

Before implementing a roadmap issue, read the issue body, `docs/IMPLEMENTATION_PLAN.md`, `docs/reference/limitations.md`, `docs/reference/security-safety.md`, and the relevant requirement/acceptance rows.

Each PR should include:

- the issue reference or closing keyword;
- a short summary of changed behavior;
- explicit safety boundaries and non-goals;
- tests and commands run;
- risks and follow-ups.

## Review Triggers

Ask for maintainer review before changing:

- dependencies, license, naming, release strategy, or public support claims;
- runtime command construction, lifecycle mutation, cleanup, daemon behavior, state migrations, policy bypass, secret handling, diagnostics, or redaction;
- distribution artifacts, signing, notarization, SBOM, provenance, installers, package channels, or release tags;
- website, GUI, cloud, tunnel, DNS, external orchestrator, multi-host, or accelerator scope.

## Fixtures And Local Material

Keep local-only files, private source material, `.DS_Store`, `.build`, `site/`, and generated artifacts out of commits. Test fixtures should be small, reviewed, deterministic, and free of real secrets.
