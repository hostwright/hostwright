# Maintainer Session Notes

## Stage goal

Establish the Hostwright Phase 0/1 foundation without deleting source material or claiming unsupported runtime behavior.

## Problem

The folder began as flat source material: planning documents, naming material, and PNG assets. It was not yet a buildable Swift repository and did not have preservation logs, public safety boundaries, module structure, or tests.

## Solution

Create a repository foundation, preserve originals with checksums, add conservative documentation, and build a dependency-free SwiftPM skeleton.

## Why this design

The source material describes a serious infrastructure project. The safe first move is not runtime behavior. The safe first move is traceability, naming control, module boundaries, and tests that prove the skeleton is coherent.

## Files changed

| File | What changed | Why it matters | What breaks if removed |
| ---- | ------------ | -------------- | ---------------------- |
| `docs/source-material/README.md` | Added preservation log. | Proves original source material was copied without deletion. | Maintainers lose the audit trail from source docs to repo foundation. |
| `assets/brand/README.md` | Added asset caveat. | Prevents PNGs from being treated as final brand assets. | Users may overclaim asset quality or transparency. |
| `README.md` | Added conservative project overview. | Defines what Hostwright is and is not. | Public scope becomes unclear. |
| `Package.swift` | Added SwiftPM package skeleton. | Makes the repo buildable. | Swift targets cannot build or test. |
| `docs/BUILD_STATUS.md` | Added local build/test limitation notes. | Explains why test targets are compile-only in this environment. | Maintainers may mistake smoke targets for full unit tests. |
| `Tests/*Smoke.swift` | Added compile-only smoke targets. | Proves public module boundaries type-check under `swift test`. | Phase 1 loses any automated check that modules import cleanly. |

## Concepts I must understand

- Desired state is what the manifest says should exist.
- Observed state is what the runtime reports actually exists.
- A plan is the diff between desired and observed state.
- `RuntimeAdapter` is the boundary that prevents shell commands from spreading through the codebase.
- `hostwrightd` currently means daemon concept scaffold, not an installed background service.
- Source material can preserve old names without making those names public product identity.

## Risks

- The adapter is not connected to Apple container yet.
- SQLite is not implemented yet.
- CLI commands are scaffolds only.
- Brand PNGs are not final production assets.

## Stubs and assumptions

- Runtime adapter implementation is non-mutating.
- State store is an interface boundary.
- Reconciler planning is minimal.
- Hostwright is treated as canonical by maintainer instruction.

## How to verify

```bash
swift build
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

## Phase 3 update: alignment and test foundation gate

### Stage goal

Adopt the canonical 10-phase first-release roadmap and create a source-grounded requirements framework before risky implementation begins.

### Problem

After Phase 2, the repository had useful non-mutating CLI behavior, but future work was not yet tied to stable requirement IDs, source claims, or acceptance gates. That creates drift risk: RuntimeAdapter, SQLite, `apply`, cleanup, and public docs could move ahead without proof or tests.

### Solution

Phase 3 adds:

- canonical 10-phase roadmap in `docs/IMPLEMENTATION_PLAN.md`;
- stable requirement IDs in `docs/requirements/REQUIREMENTS.md`;
- source-to-requirement mapping in `docs/requirements/SOURCE_TRACEABILITY.md`;
- future verification gates in `docs/requirements/ACCEPTANCE_MATRIX.md`;
- clearer limitations in `docs/reference/limitations.md`;
- Phase 3 devlog;
- copy-only site corrections where future behavior read like current support.

### Why this design

This is a control gate, not a feature phase. It keeps the project from implementing runtime mutation before the adapter boundary, durable state, planning, safety, and failure-recovery requirements are testable.

### Files changed

| File | What changed | Why it matters | What breaks if removed |
| ---- | ------------ | -------------- | ---------------------- |
| `docs/IMPLEMENTATION_PLAN.md` | Replaced stale roadmap with canonical 10-phase plan. | Future work has one phase sequence. | Maintainers may follow obsolete Phase 2-deferred wording. |
| `docs/requirements/REQUIREMENTS.md` | Added stable requirement IDs by subsystem. | Future implementation can cite exact requirements. | Features become hard to review against source intent. |
| `docs/requirements/SOURCE_TRACEABILITY.md` | Mapped source claims to requirement IDs. | Keeps source documents connected to repo work. | Drift from original documents becomes harder to detect. |
| `docs/requirements/ACCEPTANCE_MATRIX.md` | Added verification gates by phase. | Risky work must define proof before implementation. | Runtime mutation could start without acceptance criteria. |
| `docs/reference/limitations.md` | Clarified current and first-release limitations. | Prevents public overclaiming. | Users may assume `apply`, runtime observation, or SQLite exist. |
| Local website copy | Audited future runtime behavior wording as planned, not current. The website worktree is excluded from the core repo. | Keeps public docs honest while preserving the core/website boundary. | Website could imply unsupported behavior when moved to the website repo. |
| `docs/BUILD_STATUS.md` | Recorded Phase 3 verification results and limits. | Maintainer can explain current build/test truth. | Build/test claims become stale. |

### Concepts I must understand

- Requirement IDs are review anchors, not feature implementation.
- Traceability maps source intent to implementation phases.
- Acceptance criteria must say how behavior will be proven.
- Phase 3 does not make Hostwright more capable at runtime.
- Public copy is part of engineering safety because overclaims can mislead users.

### Risks

- Requirements can become stale if future phases do not update them.
- The test suite is still smoke-level because XCTest/Swift Testing are unavailable locally.
- The restricted manifest parser remains a temporary choice that needs a future dependency/ADR decision.

### How to verify

```bash
swift build
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

All four commands passed locally on 2026-06-30.

### Maintainer checklist

- [ ] I can explain why Phase 3 is a control gate, not a feature phase.
- [ ] I can explain how requirement IDs will be used during review.
- [ ] I can explain why `apply` still cannot be implemented.
- [ ] I can explain why RuntimeAdapter hardening is Phase 4.
- [ ] I can explain why website copy is tracked separately from the core repository.

### Quiz

Answer these before approving Phase 4:

1. What risk does `docs/requirements/REQUIREMENTS.md` reduce?
2. Why is source traceability useful before runtime implementation?
3. What does the acceptance matrix prove that a roadmap alone does not?
4. Why is Phase 3 not allowed to implement RuntimeAdapter process execution?
5. Which future phase starts read-only Apple container observation?
6. Which future phase starts SQLite?
7. Which future phase starts runtime mutation?
8. What current CLI output is manifest-level only?
9. Why is website copy handled separately from the core repository?
10. What must Phase 4 prove before Phase 5 can safely observe Apple container?

## Phase 4 update: RuntimeAdapter contract infrastructure

### Stage goal

Harden the runtime boundary with typed contracts before any Apple container observation begins.

### Problem

Before Phase 4, `HostwrightRuntime` had a small scaffold: desired and observed state were only service-name lists, runtime errors had two cases, and there was no command classification, timeout model, redaction model, mock adapter, or process-runner contract. That was not enough structure to safely begin read-only Apple container observation in Phase 5.

### Solution

Phase 4 adds:

- typed runtime models for desired and observed services;
- lifecycle and health state enums;
- port, mount, environment, event, capability, and adapter metadata types;
- expanded `RuntimeAdapter` protocol;
- `MockRuntimeAdapter`;
- command specs, command results, command classification, timeout model, fake process runner, and redaction policy;
- smoke checks for mock observation, command classification, redaction, planner integration, and mutation-unavailable behavior.

### Why this design

The design makes runtime assumptions testable without touching Apple container. The fake adapter and fake process runner let the repo test boundaries and error handling before any live runtime command is allowed. This keeps Phase 5 narrow: read-only observation can plug into an existing contract instead of inventing the boundary while also touching the runtime.

### Files changed

| File | What changed | Why it matters | What breaks if removed |
| ---- | ------------ | -------------- | ---------------------- |
| `Sources/HostwrightRuntime/RuntimeModels.swift` | Added typed runtime state, services, ports, mounts, events, capabilities, and metadata. | Gives future observation and planning stable data shapes. | Adapter and reconciler fall back to weak string-only state. |
| `Sources/HostwrightRuntime/RuntimeAdapter.swift` | Expanded protocol and typed runtime errors. | Defines the only future runtime boundary. | Runtime behavior would lack a stable contract. |
| `Sources/HostwrightRuntime/RuntimeCommand.swift` | Added command specs, classification, timeout, result, process-runner protocol, and fake runner. | Models process execution safely before live execution exists. | Phase 5 would need to invent execution rules while touching runtime. |
| `Sources/HostwrightRuntime/RuntimeRedaction.swift` | Added redaction policy for args, env, stdout, stderr, and errors. | Prevents fake and future runtime output from leaking credentials. | Secrets could leak into diagnostics and events. |
| `Sources/HostwrightRuntime/MockRuntimeAdapter.swift` | Added in-memory runtime scenarios. | Lets tests simulate runtime states without Apple container. | Planner/adapter behavior cannot be tested safely. |
| `Sources/HostwrightReconciler/ReconciliationPlanner.swift` | Updated planner to use typed runtime service identities and health warnings. | Integrates planner with runtime contract models. | Reconciler would remain tied to old scaffold types. |
| `Tests/HostwrightRuntimeTests/HostwrightRuntimeSmoke.swift` | Added smoke checks for models, mock adapter, classification, redaction, and mutation-unavailable behavior. | Proves Phase 4 boundaries compile and behave deterministically. | Contract regressions may pass unnoticed. |

### Concepts I must understand

- Phase 4 is contract infrastructure, not runtime integration.
- `MockRuntimeAdapter` is not a fake product feature; it is a test boundary.
- Command classification rejects mutating, forbidden, and unknown command specs in Phase 4.
- The process-runner protocol exists, but only the fake runner exists.
- Redaction is required before runtime output can become logs, events, or user-facing errors.
- Apple container observation begins in Phase 5, and mutation begins only in Phase 8.

### Risks

- The contract may still need adjustment once real Apple container output is observed.
- Fake process tests do not prove Apple container semantics.
- Redaction rules are a starting point, not a complete secret-detection system.
- Smoke tests are still weaker than XCTest or Swift Testing.

### How to verify

```bash
swift build
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

### Maintainer checklist

- [ ] I can explain why Phase 4 does not call Apple container.
- [ ] I can explain what `MockRuntimeAdapter` simulates.
- [ ] I can explain the four command classifications.
- [ ] I can explain why mutating specs are rejected in Phase 4.
- [ ] I can explain why redaction belongs in the runtime boundary.
- [ ] I can explain why Phase 5 can now focus on read-only observation.

### Quiz

Answer these before approving Phase 5:

1. What is the difference between runtime contract infrastructure and runtime integration?
2. Why does `RuntimeAdapter` expose future mutation hooks even though Phase 4 cannot mutate?
3. What does `MockRuntimeAdapter` let us test without Apple container?
4. What are the four runtime command classifications?
5. Why are mutating and unknown command specs rejected in Phase 4?
6. What does the fake process runner prove, and what does it not prove?
7. What data must be redacted before runtime output reaches users or logs?
8. Why can safe doctor/toolchain checks remain outside RuntimeAdapter?
9. Which phase first allows read-only Apple container observation?
10. Which phase first allows runtime mutation?

`swift build` proves the Swift package compiles. `swift test` currently proves the compile-only smoke targets build and link; it does not run full unit tests because this local Command Line Tools environment does not expose `XCTest` or Swift Testing. `scripts/grep-orchard.sh .` finds remaining old-name references for review. `scripts/test.sh` runs the local safe test gate.

## Maintainer checklist

- [ ] I can explain why source material was copied, not deleted.
- [ ] I can explain why runtime mutation is absent.
- [ ] I can explain why `RuntimeAdapter` exists before Apple container integration.
- [ ] I can explain why `hostwrightd` is only a scaffold.
- [ ] I can explain which old-name references are allowed.
- [ ] I can explain why the current test targets are smoke placeholders rather than full unit tests.

## Quiz

Answer these before approving the next phase:

1. Why did Phase 0 copy original source material instead of deleting or renaming it?
2. What problem does `RuntimeAdapter` solve?
3. What would break if the preservation log disappeared?
4. Which part of Phase 1 is real, and which part is scaffolded?
5. Why is `hostwrightd` not a real daemon yet?
6. What runtime behavior is explicitly not implemented?
7. Why are the PNG assets not final production brand assets?
8. Why did this environment force compile-only smoke tests instead of full unit tests?

## Phase 2 update: CLI and manifest foundation

### Stage goal

Add useful non-mutating CLI commands and a minimal `hostwright.yaml` manifest model without implementing runtime mutation.

### Problem

After Phase 0/1, the repository had module boundaries but the CLI was still a print-only scaffold and there was no Swift manifest parser or validator.

### Solution

Phase 2 adds:

- a dedicated `HostwrightManifest` module;
- a restricted Hostwright manifest subset parser;
- validation for project, service names, images, ports, volumes, health checks, and restart policy;
- dependency-free CLI command routing;
- non-mutating `validate`, `plan`, `status`, and `doctor` behavior;
- conservative docs, examples, and schema updates.

### Why this design

Manifest logic belongs outside the CLI so command routing does not become business logic. The parser is intentionally narrow because adding a full YAML dependency requires a later dependency decision. `plan` and `status` stay honest by saying runtime observation is unavailable.

### Files changed

| File | What changed | Why it matters | What breaks if removed |
| ---- | ------------ | -------------- | ---------------------- |
| `Sources/HostwrightManifest/*` | Added manifest model, parser, validator. | Keeps manifest logic outside CLI. | CLI cannot validate or plan from manifests. |
| `Sources/HostwrightCLI/*` | Added command parsing, environment abstraction, process lookup, command execution. | Makes Phase 2 CLI useful without dependencies. | `hostwright` returns to scaffold behavior. |
| `Sources/HostwrightReconciler/ReconciliationPlanner.swift` | Added non-mutating manifest dry-run plan. | Makes `hostwright plan` honest and bounded. | Plan output would drift into CLI-owned logic. |
| `Sources/HostwrightHealth/DoctorModels.swift` | Added safe doctor inputs/report. | Makes `doctor` local-only and testable. | Doctor checks would become ad hoc CLI behavior. |
| `docs/reference/*` | Updated CLI, manifest, doctor, limitations, errors. | Keeps public docs aligned with actual behavior. | Maintainer may overclaim implementation. |

### Concepts I must understand

- A restricted subset parser is not a YAML parser.
- `init` writes a file; all other Phase 2 commands are non-mutating.
- `plan` does not observe Apple container.
- `status` reports manifest-level status only.
- `doctor` looks up `container` but does not run it.
- Smoke tests are still weaker than real unit tests.

### Risks

- The parser may reject valid YAML that is outside the supported Hostwright subset.
- Smoke tests do not provide full unit-test assurance.
- `swift --version` is run only through controlled process code for doctor.

### How to verify

```bash
swift build
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```
