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
- `FoundationRuntimeProcessRunner` for policy-approved read-only specs;
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
| `Sources/HostwrightRuntime/FoundationRuntimeProcessRunner.swift` | Added guarded live runner. | Enforces read-only classification, resolution, timeout, capture, and redaction. | Future adapter work would need unsafe process execution. |
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
- `FoundationRuntimeProcessRunner` is guarded by command classification and executable resolution.

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

1. Why does `FoundationRuntimeProcessRunner` require a typed `RuntimeCommandSpec`?
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
