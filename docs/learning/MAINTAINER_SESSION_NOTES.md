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
| `docs/BUILD_STATUS.md` | Added local build/test notes. | Explains the current verification gate. | Maintainers may overstate what tests prove. |
| `Tests/*Smoke.swift` | Initially added smoke targets; later converted to XCTest. | Proves public module boundaries and behavior through `swift test`. | The repo loses automated checks. |

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
- This phase originally used smoke-level checks; the pre-Phase-7 test foundation later replaced them with XCTest.
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

`swift build` proves the Swift package compiles. `swift test list` proves XCTest discovery. `swift test` now runs real XCTest assertions. `scripts/grep-orchard.sh .` finds remaining old-name references for review. `scripts/test.sh` runs the local safe test gate.

## Maintainer checklist

- [ ] I can explain why source material was copied, not deleted.
- [ ] I can explain why runtime mutation is absent.
- [ ] I can explain why `RuntimeAdapter` exists before Apple container integration.
- [ ] I can explain why `hostwrightd` is only a scaffold.
- [ ] I can explain which old-name references are allowed.
- [ ] I can explain why the repository moved from smoke placeholders to XCTest before Phase 7.

## Quiz

Answer these before approving the next phase:

1. Why did Phase 0 copy original source material instead of deleting or renaming it?
2. What problem does `RuntimeAdapter` solve?
3. What would break if the preservation log disappeared?
4. Which part of Phase 1 is real, and which part is scaffolded?
5. Why is `hostwrightd` not a real daemon yet?
6. What runtime behavior is explicitly not implemented?
7. Why are the PNG assets not final production brand assets?
8. Why was it important to replace compile-only smoke tests with XCTest before Phase 7?

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

## Phase 5 update: read-only Apple container observation

### Stage goal

Begin Apple container integration with read-only observation infrastructure only.

### Problem

Before Phase 5, Hostwright had a strong runtime contract but no adapter that could attempt Apple container observation. The project needed a path to observe runtime state without opening a mutation path or scattering shell commands through CLI, health, state, or reconciler code.

### Solution

Phase 5 adds:

- `AppleContainerReadOnlyAdapter` behind `RuntimeAdapter`;
- `AppleContainerCommand` as the only place for Apple command shapes;
- `RuntimeExecutableResolver` for executable lookup;
- the policy-approved read-only runner then named `FoundationRuntimeProcessRunner` (replaced by `SecureRuntimeProcessRunner` in v0.0.2 issue #116);
- `AppleContainerObservationParser` for a fixture-defined observation schema;
- fixtures for empty, running, and redaction cases;
- smoke checks for missing executable, command policy, parser failure, redaction, mutation-unavailable behavior, and boundary isolation.

### Why this design

The design lets Hostwright attempt read-only observation without making unverified Apple container output into product truth. If `container` is missing, the adapter reports runtime unavailable. If output is unsupported, the parser fails closed. Mutation remains unavailable until Phase 8.

### Files changed

| File | What changed | Why it matters | What breaks if removed |
| ---- | ------------ | -------------- | ---------------------- |
| `Sources/HostwrightRuntime/AppleContainerReadOnlyAdapter.swift` | Added read-only adapter. | Gives Apple observation one RuntimeAdapter entry point. | No Phase 5 adapter exists. |
| `Sources/HostwrightRuntime/AppleContainerCommand.swift` | Isolated Apple command shapes. | Prevents command strings from spreading. | CLI/reconciler may grow ad hoc runtime command logic. |
| `Sources/HostwrightRuntime/AppleContainerObservationParser.swift` | Added fail-closed parser. | Converts fixture-defined output into typed observed state. | Runtime output cannot become typed observations safely. |
| `Sources/HostwrightRuntime/FoundationRuntimeProcessRunner.swift` | Added the original guarded live runner; v0.0.2 issue #116 later replaced this file with `SecureRuntimeProcessRunner.swift`. | Established read-only classification, resolution, timeout, capture, and redaction before the shared secure boundary existed. | Future adapter work would otherwise have needed an ad hoc process path. |
| `Sources/HostwrightRuntime/RuntimeExecutableResolver.swift` | Added executable resolver. | Proves live specs use resolved executables. | Commands could use arbitrary unresolved paths. |
| `Tests/HostwrightRuntimeTests/Fixtures/*` | Added empty, running, and redaction fixtures. | Gives parser deterministic coverage. | Parser behavior becomes unreviewable. |
| `Tests/HostwrightRuntimeTests/HostwrightRuntimeSmoke.swift` | Added Phase 5 smoke checks. | Proves boundaries compile and basic behavior holds. | Regression risk increases. |
| `docs/*` Phase 5 updates | Updated runtime docs, requirements, limits, build status, and devlog. | Keeps public claims honest. | Maintainer may overclaim runtime support. |

### Concepts I must understand

- Read-only observation is not runtime mutation.
- The CLI still does not expose observed runtime status.
- `doctor` still only checks executable presence.
- Apple command shapes must remain inside the runtime adapter layer.
- The parser schema is fixture-defined and fail-closed, not a verified public Apple CLI compatibility claim.
- The original `FoundationRuntimeProcessRunner` was guarded by command classification and executable resolution; the current `SecureRuntimeProcessRunner` adds the shared v0.0.2 subprocess guarantees.

### Risks

- Real Apple container output may not match the fixture-defined parser schema.
- SwiftPM warns that fixture `.txt` files are unhandled resources because `Package.swift` was not changed in this phase.
- Smoke tests remain weaker than XCTest or Swift Testing.
- Redaction rules are conservative but not complete.

### How to verify

```bash
swift build
swift test
scripts/grep-orchard.sh .
scripts/test.sh
git status --short
git diff --stat
git diff --name-only
```

### Maintainer checklist

- [ ] I can explain why Phase 5 is observation-only.
- [ ] I can explain why the live runner is not a general shell-out path.
- [ ] I can explain how missing Apple container degrades.
- [ ] I can explain how unsupported output fails closed.
- [ ] I can explain why `apply` and runtime mutation remain absent.

### Quiz

Answer these before approving the Phase 5 commit:

1. Why did the original runtime runner—and why does the current `SecureRuntimeProcessRunner`—require a typed `RuntimeCommandSpec`?
2. What makes a Phase 5 command executable?
3. Where are Apple container command shapes allowed to live?
4. What happens when `container` is missing?
5. What happens when Apple container output does not match the fixture schema?
6. Why does `doctor` not become runtime observation in Phase 5?
7. Which tests prove mutation remains unavailable?
8. Why are parser fixtures useful even if they are not proof of real Apple CLI output?
9. What does redaction protect in Phase 5?
10. Why does runtime mutation wait until Phase 8?

## Phase 6 update: SQLite state and event ledger

### Stage goal

Add durable local persistence for Hostwright state without adding runtime mutation.

### Problem

Before Phase 6, `HostwrightState` was only a scaffold. Hostwright could parse manifests and model read-only observations, but it could not persist desired state, observed snapshots, events, operation records, or ownership records. Without that ledger, future `apply`, recovery, cleanup, and drift decisions would have no durable memory.

### Solution

Phase 6 adds:

- a dependency-free system `SQLite3` binding through a small internal wrapper;
- explicit-path `SQLiteStateStore`;
- schema migrations;
- repository APIs for desired state, observed snapshots, events, operations, and ownership;
- redaction before persistence;
- temp-database smoke checks.

### Why this design

SQLite gives Hostwright durable local state without a service dependency. The explicit-path policy prevents hidden writes to the repository, home directory, Application Support, or global system paths. Repositories keep SQL inside `HostwrightState`, while typed manifest/runtime models remain the input/output boundary.

### Files changed

| File | What changed | Why it matters | What breaks if removed |
| ---- | ------------ | -------------- | ---------------------- |
| `Package.swift` | Linked system `sqlite3`; allowed `HostwrightState` to map manifest/runtime models. | Keeps Phase 6 dependency-free while enabling typed persistence. | State cannot compile against SQLite or typed manifest/runtime inputs. |
| `Sources/HostwrightState/SQLiteConnection.swift` | Added SQLite connection wrapper. | Isolates raw C API open, execute, query, and transactions. | SQL handling would leak or duplicate. |
| `Sources/HostwrightState/SQLiteStatement.swift` | Added prepared-statement wrapper. | Binds values and finalizes statements. | Statement lifecycle becomes unsafe. |
| `Sources/HostwrightState/SQLiteStateStore.swift` | Added explicit-path store. | Gives callers a concrete state store without hidden default writes. | State remains scaffold-only. |
| `Sources/HostwrightState/MigrationRunner.swift` | Added schema version 1. | Makes schema creation explicit and idempotent. | Database shape is unmanaged. |
| `Sources/HostwrightState/StateRecords.swift` | Added durable record types. | Defines what Hostwright persists. | Repositories lose typed records. |
| `Sources/HostwrightState/StateRepositories.swift` | Added desired, observed, event, operation, and ownership repositories. | Provides deterministic state APIs without SQL in CLI/reconciler. | Future phases cannot persist/reload state safely. |
| `Sources/HostwrightState/StateStoreConfiguration.swift` | Added explicit path policy. | Prevents hidden database writes. | Callers could assume a default path exists. |
| `Sources/HostwrightState/StateStoreError.swift` | Added typed errors. | Makes failures explainable and testable. | SQLite failures become unstructured. |
| `Sources/HostwrightState/StateJSON.swift` | Added deterministic JSON helper. | Keeps blob persistence consistent. | JSON blob encoding becomes ad hoc. |
| `Tests/HostwrightStateTests/HostwrightStateSmoke.swift` | Added temp DB smoke checks. | Exercises real migration and persistence behavior. | Phase 6 has no local verification. |
| `docs/*` Phase 6 updates | Updated roadmap, requirements, acceptance, limitations, build status, and devlog. | Keeps public claims aligned with implementation. | Maintainer may overclaim state maturity. |

### Concepts I must understand

- SQLite is local durability, not runtime control.
- A schema migration records how database structure changes over time.
- Transactions make multi-row writes atomic.
- Desired state and observed state are persisted separately.
- Operation records are future safety records; they do not execute operations.
- Ownership records enable future cleanup decisions; cleanup is not implemented.
- Explicit paths prevent hidden global or user database writes.
- Redaction must happen before values are persisted.
- Smoke tests are useful but weaker than XCTest/Swift Testing.

### Risks

- The raw SQLite wrapper is intentionally small and must remain carefully reviewed.
- Redaction is conservative and should be expanded before secrets-heavy use cases.
- JSON blobs are pragmatic now but can become harder to query later.
- Production durability, backups, corruption recovery, and concurrency behavior are not claimed yet.

### How to verify

```bash
swift build
swift test
scripts/grep-orchard.sh .
scripts/test.sh
git status --short
git diff --stat
git diff --name-only
```

### Maintainer checklist

- [ ] I can explain why Phase 6 adds persistence but not mutation.
- [ ] I can explain why there is no default database path yet.
- [ ] I can explain what each schema table stores.
- [ ] I can explain why SQL is isolated in `HostwrightState`.
- [ ] I can explain how migrations are applied idempotently.
- [ ] I can explain what gets redacted before persistence.
- [ ] I can explain why operation records do not execute anything.
- [ ] I can explain why ownership records do not imply cleanup.

### Quiz

Answer these before approving the Phase 6 commit:

1. Why is using system `SQLite3` acceptable here while adding a Swift SQLite package was deferred?
2. Why does `SQLiteStateStore` require an explicit path?
3. What does `schema_migrations` protect us from?
4. Which tables represent desired state and which tables represent observed state?
5. Why are event and operation ledgers separate?
6. What does an ownership record enable later, and what does it not do now?
7. Where is SQL allowed to live?
8. What fake secret values are redacted in the smoke test?
9. Why does Phase 6 not implement drift planning?
10. What would be dangerous about adding a default user database path too early?

## Test foundation gate: XCTest before Phase 7

### Stage goal

Replace top-level smoke/precondition tests with real XCTest cases before implementing deterministic drift planning.

### Problem

The package previously built test targets but executed zero real XCTest cases. That was acceptable only while Hostwright was mostly scaffolding. Phase 7 will add deterministic planning behavior, so test discovery and assertion-based failures must work first.

### Diagnosis

The earlier `swift -e 'import XCTest'` probe was misleading. The correct proof is a SwiftPM test target. After the local Xcode toolchain was fixed, a temporary SwiftPM XCTest package listed and executed a real XCTest case.

Hostwright now uses:

```bash
swift test list
swift test
```

as the local test-discovery and execution gates.

### Solution

Converted existing test targets from top-level smoke/precondition code into XCTest classes with assertions:

- `HostwrightCoreTests`
- `HostwrightManifestTests`
- `HostwrightCLITests`
- `HostwrightHealthTests`
- `HostwrightNetworkingTests`
- `HostwrightObservabilityTests`
- `HostwrightReconcilerTests`
- `HostwrightRuntimeTests`
- `HostwrightStateTests`

### Why this design

XCTest gives SwiftPM-discoverable test names, structured assertions, clearer failure output, async test support, and a real gate for Phase 7 planner work. The conversion does not change product behavior.

### Files changed

| File | What changed | Why it matters | What breaks if removed |
| ---- | ------------ | -------------- | ---------------------- |
| `Tests/Hostwright*Tests/*Smoke.swift` | Replaced top-level preconditions with XCTest cases. | Tests now execute real assertions. | `swift test` can regress to zero useful tests. |
| `docs/BUILD_STATUS.md` | Recorded XCTest status and corrected the misleading `swift -e` gate. | Maintainers know how to verify tests. | Toolchain confusion returns. |
| `docs/requirements/ACCEPTANCE_MATRIX.md` | Updated gates from smoke checks to XCTest cases. | Future phases must meet real test gates. | Phase 7 could proceed on weak verification. |

### Concepts I must understand

- `swift test list` proves test discovery.
- `swift test` proves the assertions execute.
- A successful build is not the same as a useful test suite.
- XCTest can work in SwiftPM even if `swift -e 'import XCTest'` fails.
- Phase 7 should not begin until this test spine is merged.

### Risks

- Some test filenames still say `Smoke.swift`, but their contents are XCTest cases.
- The test suite is broader but still not exhaustive.
- Async runtime tests use mocks and fixtures; they do not call Apple container.

### How to verify

```bash
swift build
swift test list
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

### Maintainer checklist

- [ ] I can explain why `swift test` executing zero tests was not acceptable before Phase 7.
- [ ] I can explain why a SwiftPM XCTest target is the correct XCTest probe.
- [ ] I can explain which modules now have real XCTest coverage.
- [ ] I can explain why this PR changes tests/docs only, not product behavior.

## Phase 7 update: deterministic planning and drift detection

### Stage goal

Add deterministic desired-vs-observed planning without adding runtime mutation.

### Problem

Before Phase 7, Hostwright had manifests, read-only runtime models, SQLite state records, and a small planner scaffold. It did not yet have a real plan engine that could compare desired state with observed runtime state and produce stable drift records, policy issues, planned actions, or a plan hash.

### Solution

Phase 7 adds:

- manifest-to-runtime desired-state mapping outside the CLI;
- typed drift records;
- typed plan issues;
- typed non-mutating planned actions;
- planning policy checks;
- deterministic action ordering;
- deterministic plan hash;
- CLI plan rendering that remains non-mutating and does not perform live runtime observation.

### Why this design

Planning must be proven before mutation. Phase 7 deliberately makes Hostwright better at judgment, not action. `apply`, runtime mutation, cleanup, and daemon loops stay out until later phases because they need safe intent persistence, adapter execution, recovery behavior, and confirmation design.

### Files changed

| File | What changed | Why it matters | What breaks if removed |
| ---- | ------------ | -------------- | ---------------------- |
| `Sources/HostwrightReconciler/DriftModels.swift` | Added drift, issue, action, planning input, plan, and hash models. | Gives Phase 7 a typed planning contract. | Plan output becomes ad hoc strings. |
| `Sources/HostwrightReconciler/ManifestRuntimeMapper.swift` | Maps supported manifest fields to desired runtime state. | Keeps CLI from owning planning logic. | CLI or tests would duplicate mapping. |
| `Sources/HostwrightReconciler/PlanningPolicy.swift` | Adds pre-mutation policy checks. | Blocks unsafe desired state before runtime execution exists. | Unsafe ports, mounts, or secrets may be missed. |
| `Sources/HostwrightReconciler/DriftDetector.swift` | Compares desired and observed state. | Implements real non-mutating drift detection. | Phase 7 planner has no core behavior. |
| `Sources/HostwrightReconciler/PlanRenderer.swift` | Renders redacted non-mutating plans. | Keeps CLI output honest and consistent. | Plan output may overclaim or leak detail. |
| `Sources/HostwrightReconciler/ReconciliationPlanner.swift` | Wires mapper, policy, detector, and renderer-compatible plan APIs. | Provides a single planner entrypoint. | Callers would assemble planning manually. |
| `Sources/HostwrightCLI/main.swift` | Uses Phase 7 plan rendering for `hostwright plan`. | CLI benefits from planning while staying non-mutating. | CLI remains Phase 2 manifest-only dry-run. |
| `Tests/HostwrightReconcilerTests/HostwrightReconcilerSmoke.swift` | Adds drift, policy, determinism, redaction, and boundary tests. | Proves Phase 7 behavior with XCTest. | Planner regressions become hard to catch. |
| `Tests/HostwrightCLITests/HostwrightCLISmoke.swift` | Adds plan output and redaction checks. | Proves CLI does not expose secret-like values. | CLI plan output can regress silently. |

### Concepts I must understand

- Desired state comes from the manifest.
- Observed state comes from adapter-shaped runtime snapshots, not direct shell calls.
- Drift is the typed difference between desired and observed state.
- A planned action is not execution.
- `executionAvailability` is `unavailableUntilPhase8`.
- Policy issues run before mutation exists.
- Plan hashes must not include timestamps, temp paths, raw secrets, or nondeterministic ordering.
- CLI planning is still not live runtime observation.

### Risks

- The planner can only compare fields represented in the current models.
- Env drift is not compared until observed runtime env fingerprints exist.
- Broad exposure checks are limited by the current manifest/network representation.
- Planned action names can be misread as execution unless reviewers preserve the Phase 7 boundary.

### How to verify

```bash
swift build
swift test list
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

### Maintainer checklist

- [ ] I can explain why Phase 7 is planning only.
- [ ] I can explain the difference between drift records, plan issues, and planned actions.
- [ ] I can explain why `hostwright plan` still does not inspect Apple container by default.
- [ ] I can explain why planned actions are execution-unavailable until Phase 8.
- [ ] I can explain what the deterministic plan hash proves and what it does not prove.

## Phase 8A update: real empty Apple container observation

### Stage goal

Prove and codify the first real Apple container read-only observation shape before implementing any runtime mutation.

### Problem

Phase 5 used synthetic fixtures for Apple container observation. That proved the RuntimeAdapter boundary and fail-closed parser behavior, but it did not prove Hostwright understood real Apple `container` output. Starting `apply` before a verified read-only observation shape would turn Phase 8 into assumption-driven infrastructure.

### Solution

Phase 8A verified Apple container 1.0.0 locally, started the Apple container system service, and confirmed:

```bash
container list --all --format json
```

returns the empty runtime shape:

```json
[]
```

The runtime parser now accepts that exact empty real JSON array as an empty observed runtime state. Non-empty real JSON arrays still fail closed until a real non-empty output shape is captured and reviewed.

### Why this design

An empty list is a real fact from the runtime. It is safe to support because it does not require inferring service identity, lifecycle, ports, mounts, or health. Non-empty output has not been observed yet, so supporting it would require guessing Apple CLI field names and semantics.

### Files changed

| File | What changed | Why it matters | What breaks if removed |
| ---- | ------------ | -------------- | ---------------------- |
| `Sources/HostwrightRuntime/AppleContainerObservationParser.swift` | Accepts verified empty real JSON array output. | Hostwright can parse a real empty Apple container observation. | Phase 8A would remain fixture-only. |
| `Sources/HostwrightRuntime/AppleContainerCommand.swift` | Uses `list --all --format json` for read-only list observations. | Aligns adapter command shape with verified read-only CLI output. | Adapter would keep requesting table output that the parser does not target. |
| `Tests/HostwrightRuntimeTests/Fixtures/apple-container-list-empty-real-json.txt` | Adds real empty JSON fixture. | Preserves the verified runtime output shape. | Tests would not prove the real shape. |
| `Tests/HostwrightRuntimeTests/HostwrightRuntimeSmoke.swift` | Adds parser tests for real empty JSON and unsupported real JSON shapes. | Prevents accidental broad parsing or guessing. | Parser could overclaim support for unverified output. |

### Concepts I must understand

- Phase 8A is still read-only.
- `[]` means Apple container reported no containers; Hostwright must not invent services.
- Empty real JSON support does not imply non-empty runtime observation support.
- `container list --all --format json` is read-only, but `create`, `run`, `start`, `stop`, `delete`, `remove`, `pull`, `build`, and `exec` remain forbidden.
- Parser support is not runtime mutation.
- Phase 8B is still a separate apply/mutation design and review gate.

### Risks

- Apple container 1.0.0 may change JSON fields in later versions.
- Non-empty output is still unknown.
- Hostwright CLI still does not perform live runtime observation by default.
- Supporting only empty real JSON is intentionally conservative and incomplete.

### How to verify

```bash
container system status
container list --all --format json
swift build
swift test list
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

### Maintainer checklist

- [ ] I can explain why Phase 8A came before `apply`.
- [ ] I can explain what real Apple container output was verified.
- [ ] I can explain why non-empty real output is still unsupported.
- [ ] I can explain why this phase does not mutate runtime state.
- [ ] I can explain why Phase 8B must be planned separately.

## Phase 8B update: create-only apply gate

### Stage goal

Add Hostwright's first mutation path without turning `apply` into general lifecycle management.

### Problem

Before Phase 8B, Hostwright could validate manifests, persist state, observe an empty Apple container runtime, and compute deterministic drift plans. It could not persist an apply intent, confirm that the user's plan matched the current plan, or route a runtime mutation through `RuntimeAdapter`.

### Solution

Phase 8B adds:

- `hostwright apply [path] --state-db <path> --confirm-plan <hash>`;
- explicit state database path validation;
- recomputed plan-hash confirmation before mutation;
- operation intent and `apply.started` event persistence before runtime execution;
- a single `createMissingService` execution path through `RuntimeAdapter`;
- success, failure, and ownership records after execution;
- runtime command policy for one mutating command kind: `createMissingService`.

### Why this design

The first mutation must prove the safety pipeline before expanding the feature surface. Create-only is the least destructive lifecycle action. It can be tested with fake adapters, confirmed by plan hash, recorded before execution, and blocked when local image availability is unknown. Stop, delete, cleanup, restart, volumes, broad networking, and sensitive env handling are harder to make safe and remain out of scope.

### Files changed

| File | What changed | Why it matters | What breaks if removed |
| ---- | ------------ | -------------- | ---------------------- |
| `Sources/HostwrightCLI/ApplyCommand.swift` | Adds the create-only `apply` runner. | Orchestrates validation, planning, state persistence, and RuntimeAdapter execution. | `hostwright apply` has no implementation. |
| `Sources/HostwrightCLI/CLICommand.swift` | Parses `apply`, `--state-db`, and `--confirm-plan`. | Makes mutation explicit and refuses missing confirmation. | CLI cannot route the command safely. |
| `Sources/HostwrightCLI/CLIEnvironment.swift` | Adds runtime adapter injection. | Lets tests use fake adapters and production use the local runtime adapter factory. | CLI tests would need live runtime or hidden construction. |
| `Sources/HostwrightRuntime/AppleContainerApplyAdapter.swift` | Adds guarded Apple container create-only adapter. | Keeps Apple command execution behind RuntimeAdapter. | The first mutation path would bypass the runtime boundary or not exist. |
| `Sources/HostwrightRuntime/AppleContainerCommand.swift` | Adds local image list and create command descriptors. | Isolates Apple command strings to runtime code. | Commands may leak into CLI/reconciler code. |
| `Sources/HostwrightRuntime/RuntimeCommand.swift` | Adds mutation kind and Phase 8B mutation policy. | Prevents unknown, forbidden, or unsupported mutation specs from executing. | Process execution could become a general shell-out path. |
| `Sources/HostwrightState/StateRecords.swift` | Adds succeeded and failed operation states. | Allows apply result tracking. | Failure/success records cannot be represented. |
| `Sources/HostwrightReconciler/*` | Marks missing-service create actions as Phase 8B-available. | Lets apply select exactly one executable planned action. | Apply cannot distinguish supported from unsupported actions. |
| `Tests/*` | Adds CLI, runtime, reconciler, and state XCTest coverage. | Proves plan-hash refusal, persistence, redaction, create gating, and failure records. | Mutation regressions become unreviewable. |

### Concepts I must understand

- `hostwright apply` is not general apply yet.
- The CLI orchestrates business logic but does not shell out to Apple container.
- Runtime mutation still goes through `RuntimeAdapter`.
- The runtime process runner is policy-gated, not a free shell; its current implementation is `SecureRuntimeProcessRunner`.
- The command must be typed, resolved, classified, and approved before execution.
- A matching plan hash proves the user confirmed the currently recomputed plan; it does not prove the runtime will succeed.
- State intent is written before mutation so failures can be audited.
- Phase 8B rejects mounts, sensitive env values, privileged ports, and broad bind addresses.
- The live proof created exactly one disposable container, `hostwright-proof-web`, from the approved local image `hostwright-proof-web:phase8b`.

### Risks

- The plan-confirmation flow is still rough because there is no dedicated `apply --dry-run` preview command.
- Non-empty real Apple container image list parsing is supported only for the verified object shape used in the proof.
- Broader real Apple container list parsing is supported only for the verified builder-container and proof-container shapes.
- Create-only support could be mistaken for full lifecycle management if docs or PR text are sloppy.

### How to verify

```bash
container system status
container image list --format json
swift build
swift test list
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

### Maintainer checklist

- [ ] I can explain why Phase 8B supports only createMissingService.
- [ ] I can explain why `--state-db` is required.
- [ ] I can explain why `--confirm-plan` is required.
- [ ] I can explain what is persisted before mutation.
- [ ] I can explain how success and failure are recorded.
- [ ] I can explain why the live proof does not mean general lifecycle management exists.
- [ ] I can explain why stop/delete/restart/remove/cleanup remain forbidden.

## Phase 8B live proof update: disposable Apple container create

### Stage goal

Prove Hostwright can perform its first real runtime mutation without widening the mutation surface beyond one reviewed create-missing-service action.

### Problem

Fake process runner tests proved the safety pipeline, but they did not prove Apple container would accept the actual create command or return parseable real output after creation. Without a live proof, Phase 8B would still depend on an unverified runtime assumption.

### Solution

An approved disposable image was built outside the repository at `/tmp/hostwright-phase8b-live-proof` using Apple container. Hostwright then ran:

- a bogus-hash `hostwright apply`, which refused mutation and printed the expected plan hash;
- a confirmed `hostwright apply`, which created exactly one container named `hostwright-proof-web`;
- a repeat apply with the old hash, which failed before mutation because the observed plan changed;
- exact cleanup of `hostwright-proof-web` and `hostwright-proof-web:phase8b`.

### Why this design

The proof exercises the real runtime path while keeping the blast radius tiny. It proves local-image gating, plan-hash confirmation, RuntimeAdapter execution, state/event persistence, observed-state parsing, stale-plan refusal, and exact cleanup of the proof resource. It does not prove stop/delete/restart/remove/cleanup support, daemon reconciliation, or general Apple container compatibility.

### Files changed

| File | What changed | Why it matters | What breaks if removed |
| ---- | ------------ | -------------- | ---------------------- |
| `Sources/HostwrightRuntime/AppleContainerObservationParser.swift` | Parses verified real builder-container and proof-container list shapes. | Lets Hostwright recognize the actual post-create proof output without guessing broader Apple JSON. | Repeat planning cannot observe the proof container. |
| `Sources/HostwrightRuntime/AppleContainerApplyAdapter.swift` | Parses verified object-based image-list output by `configuration.name` and known image annotations. | Allows local image availability gating against real Apple image output. | Live create remains blocked because Hostwright cannot prove the local image exists. |
| `Tests/HostwrightRuntimeTests/Fixtures/apple-container-image-list-real-json.txt` | Adds a sanitized real-shape image-list fixture. | Preserves the verified image output shape. | Image parser support becomes assumption-based. |
| `Tests/HostwrightRuntimeTests/Fixtures/apple-container-list-builder-real-json.txt` | Adds a sanitized builder-container fixture. | Proves Apple builder runtime state is ignored for Hostwright planning. | Parser may treat Apple-owned builder internals as Hostwright services. |
| `Tests/HostwrightRuntimeTests/Fixtures/apple-container-list-proof-created-real-json.txt` | Adds a sanitized created proof-container fixture. | Proves Hostwright can parse its created container. | Repeat apply cannot distinguish created from missing. |
| `Tests/HostwrightRuntimeTests/HostwrightRuntimeSmoke.swift` | Adds XCTest coverage for real proof fixtures. | Prevents regressions in the exact verified shapes. | Broader or broken parser behavior may slip in. |
| `docs/*` | Records the live proof result and remaining limits. | Maintainers can defend what is proven and what is not. | Reviewers may think Phase 8B is either blocked or broader than it is. |

### Concepts I must understand

- A live proof is stronger than a fake process runner test, but it is still narrow.
- Hostwright owns only resources it explicitly creates and records.
- Apple builder internals and base images are not Hostwright-owned proof resources.
- The old confirmation hash fails after creation because observed state changed.
- That stale-hash failure is a safety feature, not a bug.
- The parser must support only reviewed shapes and fail closed on unknown shapes.
- Exact proof cleanup is not the same as product cleanup or garbage collection.

### Risks

- The proof used Apple container 1.0.0; future Apple CLI JSON may change.
- The created container is observed as `stopped`, so Phase 9 must handle start/status/health carefully.
- Desired `nil` bind address versus observed `0.0.0.0` currently appears as port drift; that needs normalization or an explicit policy decision later.
- The downloaded base image and Apple builder container remain outside Hostwright ownership.

### How to verify

```bash
container system status
container image list --format json
container list --all --format json
swift build
swift test list
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

### Maintainer checklist

- [ ] I can explain why this proof used exactly one disposable service.
- [ ] I can explain why `container build` was machine prep for the proof, not Hostwright product behavior.
- [ ] I can explain why `hostwright apply` needed the plan hash before mutation.
- [ ] I can explain what state records were written.
- [ ] I can explain why repeat apply with the old hash refused to mutate.
- [ ] I can explain why the proof container/image cleanup was allowed but general cleanup is still not implemented.

## Phase 9 update: operability, managed start, logs, events, and safe cleanup

### Stage goal

Make Hostwright usable for local operation after create-only convergence: observe status, read bounded logs, inspect persisted events, start an eligible stopped managed service, and clean up exact owned stopped/created/exited containers.

### Problem

After Phase 8B, Hostwright could create one missing service safely, but it could not operate the service afterward. There was no live CLI status path, no log command, no event rendering, no restart-policy-aware start, and no product cleanup path based on ownership records.

### Solution

Phase 9 adds:

- `hostwright status [path] --state-db <path>`;
- `hostwright logs <service> [path] [--tail <n>] [--state-db <path>]`;
- `hostwright events --state-db <path> [--project <name>]`;
- `hostwright cleanup [path] --state-db <path> --dry-run`;
- `hostwright cleanup [path] --state-db <path> --confirm-cleanup <token>`;
- one new `apply` executable action: `startManagedService`, only when restart policy allows it;
- RuntimeAdapter log, start, and delete command specs with strict command policy.

### Why this design

Operability should grow from ownership and observation, not from broad lifecycle commands. Status and logs are read-only. Start is bounded by restart policy and exact observed identity. Cleanup is destructive, so it requires dry-run, a token, ownership records, live observation, exact resource identifiers, and non-running lifecycle. Images, volumes, networks, unmanaged resources, and broad flags stay out of scope.

### Files changed

| File | What changed | Why it matters | What breaks if removed |
| ---- | ------------ | -------------- | ---------------------- |
| `Sources/HostwrightCLI/StatusCommand.swift` | Adds live RuntimeAdapter status with explicit state DB persistence. | Lets maintainers see desired vs observed state honestly. | `status --state-db` cannot record or render live status. |
| `Sources/HostwrightCLI/LogsCommand.swift` | Adds bounded, redacted log reads through RuntimeAdapter. | Provides local diagnostics without follow/attach/exec. | Operators cannot inspect service logs safely. |
| `Sources/HostwrightCLI/EventsCommand.swift` | Adds event ledger rendering. | Makes persisted operations reviewable. | State events remain hidden in SQLite. |
| `Sources/HostwrightCLI/CleanupCommand.swift` | Adds dry-run and token-confirmed cleanup for eligible owned stopped/created/exited containers. | Introduces destructive behavior with explicit safety gates. | Cleanup candidates cannot be reviewed or executed safely. |
| `Sources/HostwrightCLI/ApplyCommand.swift` | Adds one managed-start action after plan confirmation. | Allows restart-policy-permitted stopped services to start without broad lifecycle support. | Phase 9 cannot recover stopped created services. |
| `Sources/HostwrightRuntime/*` | Adds logs, start, delete command descriptors and policy checks. | Keeps runtime execution behind RuntimeAdapter and rejects forbidden flags. | CLI could drift into unsafe or scattered shell behavior. |
| `Sources/HostwrightReconciler/*` | Adds restart-policy-aware start availability. | Keeps start decisions in planning, not ad hoc CLI code. | Apply cannot know when start is allowed. |
| `Tests/*` | Adds XCTest coverage for status, logs, events, cleanup, managed start, and command policy. | Proves Phase 9 safety rules are executable. | Future regressions would be mostly manual review. |

### Concepts I must understand

- RuntimeAdapter is still the only path for Apple container runtime behavior.
- `status --state-db` observes runtime but does not mutate.
- `logs` reads a bounded tail only; it does not follow, attach, or exec.
- `events` reads persisted state only; it does not observe runtime.
- `apply` still executes exactly one action after a matching current plan hash.
- `startManagedService` is allowed only for stopped/created/exited managed services when restart policy is `on-failure` or `unless-stopped`.
- Cleanup is destructive and therefore requires dry-run, ownership, live observation, exact resource IDs, non-running lifecycle, and a matching token.
- Hostwright still does not delete images, volumes, networks, unmanaged containers, or broad resource sets.

### Risks

- Cleanup relies on ownership records being correct.
- Live status can report runtime lifecycle but still does not prove application-level health or reachability.
- Log output can still contain unusual secret formats not covered by the current redaction heuristics.
- Managed start does not implement a daemon restart loop or backoff.
- Live proof caught a real ownership bug: managed start originally overwrote cleanup eligibility. The fix keeps create ownership cleanup-eligible after start.

### Live proof

The proof used one disposable container:

- project `phase9proof`;
- service `web`;
- existing local image `docker.io/library/python:alpine`;
- command `python3 --version`;
- container `hostwright-phase9proof-web`.

It proved create, live status, managed start, logs, events, dry-run cleanup, confirmed cleanup, and final absence from `container list --all`. The first proof attempt was stopped after it found the ownership downgrade bug; the leftover exact proof container was deleted without broad flags before rerunning the fixed proof.

### How to verify

```bash
swift build
swift test list
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

### Maintainer checklist

- [ ] I can explain why cleanup is separate from apply.
- [ ] I can explain why cleanup needs a dry-run token.
- [ ] I can explain why Hostwright deletes containers but not images or volumes in Phase 9.
- [ ] I can explain why start is restart-policy-gated.
- [ ] I can explain why `logs` is bounded and non-following.
- [ ] I can explain which events are persisted by status, logs, apply, and cleanup.

## Phase 10 update: release hardening for v0.1.0-alpha.1

### Stage goal

Prepare Hostwright for an honest source-only GitHub pre-release named `Hostwright v0.1.0-alpha.1`.

### Problem

After Phase 9, Hostwright had real local behavior but no public-release discipline. The CLI still reported a development placeholder version, release tag policy was not centralized, install/build instructions were scattered, and the artifact decision was not explicit.

### Solution

Phase 10 sets `HostwrightIdentity.version` to `0.1.0-alpha.1`, adds release process docs, drafts `v0.1.0-alpha.1` release notes, expands compatibility/install/security docs, and adds XCTest coverage for release-doc truth.

### Why this design

The first public release is an alpha, not a production launch. Source-only release avoids pretending we have signing, notarization, installers, checksums, SBOM, or provenance. `phase-*` tags remain internal checkpoints; only `v*` tags may get GitHub Releases.

### Files changed

| File | What changed | Why it matters | What breaks if removed |
| ---- | ------------ | -------------- | ---------------------- |
| `Sources/HostwrightCore/HostwrightIdentity.swift` | Central version is `0.1.0-alpha.1`. | Gives CLI/runtime one version source of truth. | `hostwright --version` can drift from release docs. |
| `docs/release/RELEASE_PROCESS.md` | Defines tag policy, release ladder, and source-only artifact policy. | Prevents random public releases and phase-tag releases. | Maintainers may tag or publish inconsistently. |
| `docs/release/v0.1.0-alpha.1-notes.md` | Drafts the GitHub pre-release body. | Makes release claims reviewable before publishing. | Release notes become ad hoc and easy to overclaim. |
| `docs/reference/install.md` | Adds source build instructions. | Users can build without installer/Homebrew claims. | Alpha users lack a safe install path. |
| `docs/reference/security-safety.md` | Documents runtime, apply, cleanup, and redaction boundaries. | Keeps safety limits visible. | Users may assume broad lifecycle or cleanup support. |
| `Tests/*` | Adds release-doc and example/schema assertions. | Makes public-release truth part of `swift test`. | Version or docs can drift silently. |

### Concepts I must understand

- `phase-*` tags are engineering checkpoints; `v*` tags are public release tags.
- GitHub Releases are only for `v*` tags.
- `v0.1.0-alpha.1` is source-only.
- No binaries, installers, Homebrew formula, signing, or notarization are claimed.
- `hostwrightd` is still a scaffold.
- Not production ready means users should expect sharp edges and limited support.

### Risks

- Users may overread `v0.1.0-alpha.1` as stability unless docs keep saying alpha and not production ready.
- Source-only install still requires a working Swift/Xcode and Apple container environment.
- The release notes must be reviewed again before the public GitHub pre-release is created.

### How to verify

```bash
swift build
swift test list
swift test
scripts/grep-orchard.sh .
scripts/test.sh
git tag --list | sort
git ls-files | rg "\\.DS_Store|\\.build|site/|\\.env|\\.pem|id_rsa|hostwright_naming_convention|DIAGRAM_BRIEF" || true
```

### Maintainer checklist

- [ ] I can explain why this is `v0.1.0-alpha.1`, not `v1.0.0`.
- [ ] I can explain why the alpha is source-only.
- [ ] I can explain why no GitHub Release is created from a `phase-*` tag.
- [ ] I can explain what must pass before creating the public `v0.1.0-alpha.1` tag.
- [ ] I can explain what Hostwright still does not support.
