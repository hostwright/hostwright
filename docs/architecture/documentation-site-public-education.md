# Documentation Site And Public Education

> **Historical plan, now executable:** v0.0.2 Phase 01 adds cross-repository typecheck/build/link/quickstart and truth-contract checks; Phase 15 repeats the full site/docs qualification for GA.

Status: Phase 37 source-of-truth and information architecture boundary.

Phase 37 defines how `hostwright.dev` should present Hostwright docs. It does not implement a website, frontend, hosted docs deployment, analytics, search service, content pipeline, or marketing campaign in this core repository.

## Ownership Boundary

Core repository owns source reference truth:

- current support and limitations;
- CLI, manifest, state, runtime, safety, and release reference docs;
- example manifests under `examples/`;
- release notes and release gates;
- requirements, acceptance, and source traceability;
- docs guard tests that block unsupported current-support claims.

The separate `hostwright.dev` repository owns presentation:

- page layout;
- navigation;
- generated static pages;
- visual design;
- search UI;
- copy editing that preserves the source truth from this repository.

Website copy must link back to the source docs when it describes current behavior. If the website needs a product claim that is not in this repository, the source claim must be added and reviewed here first.

## Information Architecture

The public docs site should use this structure:

| Site section | Core source of truth | Notes |
| --- | --- | --- |
| Overview | `README.md`, `docs/reference/limitations.md` | State source-only alpha status and non-goals before tutorials. |
| Install from source | `docs/reference/install.md`, `docs/release/distribution-readiness.md` | No binary, installer, Homebrew, signing, notarization, SBOM, or provenance claim. |
| Quick start | `README.md`, `docs/reference/cli.md`, `examples/single-service/hostwright.yaml` | Use `hostwright init`, `validate`, `plan`, and `doctor` before any mutation. |
| Concepts | `docs/architecture/runtime-adapter.md`, `docs/architecture/reconciliation.md`, `docs/architecture/state-store.md`, `docs/architecture/policy-engine.md` | Explain boundaries before behavior. |
| Tasks | `docs/reference/cli.md`, `docs/guides/stack-import.md`, `examples/` | Each task must name whether it is read-only, state-writing, or mutating. |
| Reference | `docs/reference/cli.md`, `docs/reference/manifest.md`, `docs/reference/error-codes.md`, `docs/reference/policy.md` | Keep command and manifest syntax sourced from tested docs. |
| Operations | `docs/reference/security-safety.md`, `docs/reference/team-workflow.md`, `docs/architecture/daemon.md` | Preserve secure selected state paths, redaction, confirmation, and ownership gates. |
| Release | `docs/release/RELEASE_PROCESS.md`, `docs/release/v0.1.0-alpha.1-notes.md` | Release copy must match artifact policy and current limitations. |
| Roadmap and research | `docs/IMPLEMENTATION_PLAN.md`, research decision records | Planned, deferred, rejected, and research-only work must not read as current support. |

## Tutorial And Task Outlines

Tutorials should start from tested command surfaces and checked-in example manifests.

### Source Install And Doctor

- Build from source with `swift build`.
- List tests with `swift test list`.
- Run `swift test` and `scripts/test.sh`.
- Run `swift run hostwright --version`.
- Run `swift run hostwright doctor --output json`.
- Link to source-only release and distribution readiness docs.

### Single-Service Local Plan

- Use `examples/single-service/hostwright.yaml`.
- Run `hostwright validate examples/single-service/hostwright.yaml`.
- Run `hostwright plan examples/single-service/hostwright.yaml --output json`.
- Explain that `plan` is non-mutating and does not inspect runtime by default.
- Mention confirmed `apply` only as a separate, explicit, plan-hash-gated step that also needs a local image and explicit state database path.

### App Suite Review

- Use `examples/app-suite/hostwright.yaml`.
- Run `hostwright validate` and `hostwright plan`.
- Explain policy, health, restart, and multi-service planning behavior.
- State that current `apply` executes at most one supported action and is not full Compose parity.

### Operations And Recovery

- Use explicit `--state-db <path>` for stateful commands.
- Cover `status`, `logs`, `events`, `recovery`, `diagnostics`, and `cleanup --dry-run`.
- Explain redaction, local-only diagnostic bundles, event filtering, and exact cleanup confirmation tokens.
- State that cleanup deletes only exact eligible Hostwright-owned non-running containers.

### Stack Import

- Use `hostwright import-stack <path> [--output text|json]`.
- Present import as conversion-only.
- Link rejected Compose, Kubernetes, DNS, tunnel, cloud, secrets/configs, named-volume, and lifecycle semantics to limitations.

## Copy Rules

Public education copy must:

- distinguish `implemented`, `planned`, `deferred`, `rejected`, and `research-only`;
- link current support claims to reference docs or tests in this repository;
- put unsupported behavior in direct language, not footnotes;
- keep source-only alpha artifact language intact;
- describe runtime mutation only through `apply --confirm-plan` and `cleanup --confirm-cleanup` gates;
- avoid benchmark, capacity, performance, compatibility, support, or production-readiness claims without matching evidence;
- avoid implying that the website, GUI, cloud control plane, tunnel, DNS, multi-host platform, scheduler API, accelerator support, Docker API, CRI, Kubernetes, or Compose parity exists.

## Release Notes And Limitations

Website release notes must mirror `docs/release/` and must not create new release facts. Every release page should link to:

- current artifact policy;
- compatibility matrix;
- limitations;
- safety and security notes;
- verification checklist;
- known unsupported behavior.

Limitations pages should be searchable and linked from every tutorial that touches an unsupported or planned area.

## Blocked Evidence

The current core repository has no:

- documentation-site frontend;
- hosted docs deployment;
- website analytics or telemetry;
- website search index;
- public visual assets for site design;
- production tutorial proof for multi-service apply;
- binary install tutorial proof;
- public performance benchmark data.

Those require separate website or release work and maintainer review.

## Rejected Paths

Phase 37 rejects:

- implementing `hostwright.dev` inside this core repository;
- adding marketing-only support claims;
- generating docs from untested command examples;
- publishing benchmark, capacity, binary-install, tunnel, cloud, DNS, accelerator, multi-host, CRI, Kubernetes, Docker API, or Compose parity tutorials as current support;
- adding website dependencies, deployment config, analytics, or GUI code to this repository.
