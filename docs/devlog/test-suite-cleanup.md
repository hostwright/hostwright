# Test cleanup for the supported local product

Scope decision: [ADR 0016](../design/adr-0016-release-focused-test-suite.md), accepted 2026-09-22. This supersedes the earlier cleanup's requirement to keep deep deferred-feature tests. Historical ADRs, scripts, release records and evidence remain intact.

## Result

| Measure | Starting working tree | Retained suite | Change |
| --- | ---: | ---: | ---: |
| Swift lines under Tests | 248,615 | 218,164 | **30,451 removed (12.2%)** |
| Swift files under Tests | 480 | 432 | **48 net fewer** |
| Lines in the five changed test/check scripts | 718 | 666 | **52 removed** |
| Discovered test identifiers | 4,032 | 3,478 | 555 removed; one release-boundary check added |
| Dedicated targets retired | — | — | **6** |

49 Swift files were deleted and one small shared tracked-input helper was added. The unused `scripts/check-site-contract.py` wording checker was also deleted; actual link validation remains. Across test code and the changed check scripts, that is **30,503 net lines and 49 net files removed**. Counts use the actual starting working tree, including the earlier uncommitted suite splits; no file moves, earlier savings, build output, dependencies, or skipped execution are credited as deletion.

The six retired targets are `HostwrightClusterTests`, `HostwrightAcceleratorTests`, `HostwrightAcceleratorXPCTests`, `HostwrightDockerEngineTests`, `HostwrightPodSandboxTests`, and `HostwrightPhase09QualificationToolTests`.

## Complete inventory and deletion ledger

- [Suite dispositions](test-suite-dispositions.tsv) cover all 481 original/current Swift file entries, all 15 Python/Go test-file entries, 17 test runners/centralized checks, and the current fuzz driver with six seed corpora.
- [Deletion ledger](test-suite-deletions.tsv) maps all **555 removed discovered identifiers** and the retired website wording command, with **zero unexplained removals**.
- Discovered removals: 324 deferred implementation cases, 192 historical qualification cases, 32 source/prose trivia cases, five test-double self-checks, and two consolidated identifiers.

The review included CLI, State, Runtime and every remaining target. Distinct parser, authenticated command, persistence, transport and integration boundaries remain independently covered. Local team approval/RBAC tests remain because shipped commands consume that authority. Accelerator schema-v23 migration remains because current SQLite upgrades traverse it. Scheduler tests retain ordinary reservations, fencing, pressure generation checks, hard filters and the independent oracle. The oracle's seed `0x10_209_214`, default 48 generated scenarios and 24 exact scenarios are unchanged.

Representative retained protection, in addition to the complete disposition inventory:

| Supported boundary | Retained suites |
| --- | --- |
| Manifest v3, migration and Compose | `ManifestMigrationTests`, `ManifestV2StrictTests`, `HostwrightImportTests` |
| Authentication, command authority, confirmation and disconnects | `RBACAuthorizationEngineTests`, `CLIControlAuthorizationScopeTests`, `PersistentControlStreamIntegrationTests`, `DesktopOperationsModelTests` |
| Ownership, idempotency, fencing, cancellation and compensation | `HostwrightRuntimeTests`, `LifecycleSagaExecutorTests`, `LifecycleProcessRecoveryIntegrationTests` |
| SQLite upgrades through v24, corruption, snapshots and rollback | `AcceleratorSchemaV23MigrationTests`, `StateUpgradeTests`, `HostwrightStateTests`, `HostwrightStateIntegrationTests` |
| Scheduling and reservation authority | `SchedulerEngineTests`, `SchedulerAdmissionRepositoryTests`, `SchedulerAdmissionPreemptionStateTests`, `Phase10SchedulerQualificationTests` |
| Process/provider isolation and image trust | `SecureSubprocessTests`, `ProductionNetworkProviderSecurityTests`, `ImageTrustVerifierTests`, `LifecycleImageTrustPreflightTests` |
| Secrets, networking and storage | `HostwrightSecretsIntegrationTests`, `NetworkPolicyCompilerTests`, `LocalStorageProviderDataProtectionTests`, `StorageBackupEngineTests` |
| Artifact integrity and durable installation lifecycle | `ReleaseQualificationRegistryTests`, `DistributionIntegrationTests`, `DistributionDurableLifecycleTests` |

## Consolidation and support cleanup

| Removed or repetitive group | Retained protection |
| --- | --- |
| Duplicate legacy ownership migration setup | `HostwrightStateTests/testMigrationBackfillsLegacyOwnershipRuntimeAdapter`, named cases `legacy owner only` and `existing canonical owner`, each using a fresh v4 database |
| Separate default-state apply parser test | Accepted default-state apply and rejected missing-confirmation/force argv cases in `HostwrightCLITests/testCommandParserRecognizesSupportedCommands` |
| Repeated capability lookup/assertion blocks | Named capability/status table, required release evidence, deferred availability and packaging exclusions |
| Mixed preemption-state scenarios | Existing decision-artifact, pending-reservation, pressure CAS, project-scope, fencing and host-pressure cases retained under their existing identifiers |
| Deferred trace generators and fixture builders | Removed after their final consumers; shared generated safety verification remains |
| Source/prose checks | Current executable checks, parsed package metadata, central documentation validation and package/process-boundary lint |

Literal `source.contains` / `script.contains` calls fell from 506 to 25. Remaining calls primarily inspect generated installer scripts, a signing requirement, or manifest/runtime inputs. Four desktop source assertions remain with the user's pre-existing desktop edits. Unique production-process, test-double, direct CLI and prohibited-operation guards now live in the existing boundary lint, with negative self-tests. The central current-truth validator also drops exact prose, capability call spelling, ticket numbers and historical roadmap wording; contract/schema consistency, examples and immutable digests remain.

The recording transport consolidation from the earlier cleanup is not counted again. No universal fixture framework or additional suite splitting was introduced.

## Fixtures and runner

Local example checks and release documentation snapshots select tracked working-tree files. Explicit qualification snapshots still validate every supplied example, and dirty formal evidence remains non-promotable. The input-selection self-test verifies invalid tracked examples fail, modified tracked contents are read, unrelated untracked examples are ignored, and invalid explicitly supplied examples fail. The local demo directory was left untouched.

`pr`, `full`, and `qualification distribution|release|live|all` remain available. The three retired Phase 09 shard names each return exit 64. Expensive clean-release builds remain in distribution qualification. All five durable lifecycle sentinel identifiers and their PR membership are unchanged.

The documentation validator's registered SHA-256 and byte length were refreshed for the edited validator. This is the only production-source change from this cleanup; it changes the current provider pin, not runtime behavior or public contracts. Historical evidence was not rewritten. Production dependencies, APIs and schemas are unchanged. Twelve files carrying pre-existing user changes were verified byte-for-byte unchanged; existing Package.swift edits were preserved around the test-target changes.

## Verification

The complete retained suite was executed through the PR lane and each current qualification shard, with identifiers reconciled against discovery. This avoids repeating the expensive clean builds in a second monolithic invocation.

| Lane | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| PR, including five durable sentinels | 3,389 | 4 | 0 |
| Release qualification | 35 | 0 | 0 |
| Live qualification | 0 | 6 | 0 |
| Distribution qualification | 44 | 0 | 0 |
| **Complete retained inventory** | **3,468** | **10** | **0** |

Governance validation/self-test, roadmap generation, current-truth validation/self-test, package/process-boundary lint/self-test, integration, all eight Python test scripts, guest Go tests and Linux/arm64 guest test compilation passed. Documentation quickstarts passed. Discovery reconciliation covers all 3,478 identifiers exactly once across these lanes, with no missing, unexpected or duplicated IDs. After the final central-validator prose cleanup, all 80 release-target tests passed again in the main workspace. Six probes confirmed that documentation wording changes pass while invalid examples, product/schema drift and altered immutable history fail.

The original recorded execution had 95 failing cases. 88 belong to requirements explicitly retired here. The seven current-product failures were retained and repaired by corpus/snapshot isolation; focused reruns and the current PR/release lanes pass them.

Ten retained cases require unavailable opt-in environments: scheduler performance, live registry TLS, two attended Tahoe/helper cells, and six live lifecycle/network cells. No skips were converted to passes. Developer ID signing, notarization and attended clean-host promotion were not established by this local run. All six fixed parser/protocol seed corpora replayed successfully; this is not a timed sanitizer/libFuzzer qualification claim. The clean-builder reproducibility test retains its committed-source fixture; it does not promote this uncommitted working tree as release evidence.

A supplemental release run in the temporary checkout hit six existing unsafe-path guards and included one already-retired source check from its earlier snapshot. All 80 current release-target tests passed in the main workspace; those temporary-path failures were not removed or weakened.

## Fault checks

Six representative faults were injected one at a time in an isolated checkout, with each source restored afterward. The six selected retained tests first passed without faults.

| Fault | Retained test |
| --- | --- |
| Subject receives another subject's roles | `RBACAuthorizationEngineTests/testNoBindingDefaultsToDenyAndUnknownOperationsRequireOwnerAdmin` |
| Ownership label is not bound to the exact resource | `HostwrightRuntimeTests/testCreateMissingServiceMutationPolicyRejectsTamperedOwnershipBinding` |
| Mismatched confirmation token accepted | `RuntimeProviderMigrationTests/testCancellationCompensatesAndConfirmationMismatchNeverMutates` |
| Reservation exceeds available capacity | `SchedulerAdmissionRepositoryTests/testAdmissionRejectsStaleInputDuplicateWorkloadCapacityAndEpoch` |
| Failed transaction commits instead of rolling back | `HostwrightStateIntegrationTests/testTransactionFailureRollsBackPartialWrites` |
| Runtime text redaction bypassed | `HostwrightRuntimeTests/testRedactionHandlesSensitiveEnvironmentArgumentsAndJSON` |

All six faults produced failures in their named retained tests after successful compilation. Each source was restored byte-for-byte; the final six-test run passed with no failures or skips. Faults never touched the main working tree.

## Timing

Applicable baseline XCTest time was 4,145.376 seconds. Removed cases accounted for 819.966 seconds of that baseline. Matched retained PR cases took 383.062 seconds before and 386.415 seconds now; this is normal run-to-run variation, not an execution speedup claim. The material runtime reduction comes from retired requirements and bounded repository fixtures.

Complete retained-suite XCTest time was **3,303.663 seconds (55m 3.663s)**; native Swift Testing took 0.359 seconds of suite wall time. The later 80-case release-target recheck took 23.589 seconds. Compared with the earlier 4,145.376-second baseline, the observed primary-lane XCTest total is 841.713 seconds lower; compiler/cache and machine-load variation also affect the clean builds, so that difference is not attributed entirely to test removal. Raw per-case timings, normalized XCTest xUnit and native Swift Testing xUnit remain in the local verification artifacts. Qualification timings include real clean builds; live/skipped environments are excluded from performance claims.

Private logs, normalized xUnit, discovery, per-case timings, mutation checks and final reconciliation are retained locally in `/tmp/hostwright-release-test-cleanup-nfbs2e2f`. The repository ledgers record permanent scope and removal mappings.

## Integration branch based on main

The review branch starts at `ec8914ca83131f2516ddbef0a632bb1b46d3efa0` and excludes the separately owned desktop/release changes in PRs #323 and #324. Their 12 local files and two DesktopModel dependency additions remain untouched in the original checkout.

Against that committed base, Swift test code changes from **248,601 lines in 439 files to 218,034 lines in 432 files**: **30,567 net Swift lines and seven net Swift files removed**. Including the five changed test/check scripts, the integration patch removes **30,619 net lines and eight net files**. Earlier class-extension splits are included in this patch, which is why its net file count differs from the later cleanup batch above. Moves receive no line-reduction credit.

The branch excludes four desktop tests belonging to PR #323, so its expected discovery is **3,474 identifiers**, versus 3,478 in the completed combined-working-tree run above. Those four are neither cleanup deletions nor retired requirements. The deletion ledger now includes the three previously consolidated identifiers from the earlier pass, for **558 removals against main**, plus the retired website wording command. The added packaging-boundary test is unchanged. Branch-specific CI will verify this isolated scope; the combined-working-tree results above are not represented as a clean-branch run.

## Earlier conservative cleanup measurements

The following record predates ADR 0016 and is preserved as history. Its smaller totals and preservation policy do not describe the current cleanup.


Latest follow-up (2026-09-22): 4,032 discovered tests after three mapped removals; 248,615 Swift test lines (116 fewer than the original baseline). The initial full-run results below predate this follow-up; its focused verification is recorded at the end.

Baseline: Swift 6.3.3 on arm64 macOS 26.6.2. Tracked first-party files were measured at their working-tree contents before edits; the after count includes their new replacement/helper files. Build output, dependencies, and pre-existing untracked material are excluded. Pre-existing changes were preserved.

## Preserved coverage

- Discovery: 4,035 identifiers before and after; no additions or deletions.
- Four split suites retain their original XCTest class and method names: CLI (95), Runtime (78), Manifest (40), State (40).
- 252 of those 253 method bodies are unchanged apart from fixture calls. The remaining parser method retains all 37 accepted and 29 rejected argument/result cases.
- Scheduler qualification implementation lines match the original after normalizing imports, the namespace extension, shared scanner visibility, and three immutable read-access changes. Verifier and measurement constructors remain fileprivate.

## Assertion mapping

| Removed source check | Retained verification |
| --- | --- |
| Bootstrap helper-call text | BootstrapControlAPITests.testPersistentRouteIsRejectedBeforeAnyCommandExecution |
| Executor validation-call text | CLIControlCommandExecutorTests.testDeclaredAuthorizationScopeMismatchRejectsBeforeCLIExecution |
| Routing branch expression text | HostwrightCommandRunnerTests dispatch/no-fallback tests and CLIControlRouteTests disjoint-route contract |
| LocalControlAPI helper-call text | LocalControlAPIIntegrationTests.testRealFilesAndSQLiteServeAllFiveApprovedOperations |
| One-shot diagnostic wording in source | Existing plan-only source guard and executable integration check for HW-API-001 |
| Package.swift formatting/substrings | Same test identifier now reads swift package dump-package target/dependency metadata |
| Four Gate 10 prerequisite literals in source | Same test verifies emitted manifest externalPrerequisites fields |

## Shared setup

- Three byte-equivalent registry transports now share one target-local implementation (two duplicate copies eliminated).
- Five CLI temporary-directory/database implementations share two target-local helpers (three duplicate wrappers eliminated).
- Six migration-store implementations across five suites now use two sync/async helpers and one private directory builder, preserving schema versions, prefixes, permissions, and cleanup.
- Three qualification suites share one root/process/path/permissions scaffold and result type (two duplicate scaffolds eliminated); branch and environment requirements are unchanged.

## Measurement

- Swift Tests: 248,731 → 248,668 lines (63 fewer).
- Swift Sources: 362,456 lines, unchanged.
- Rounded test share remains 40.7%; moved lines are not counted as savings.
- Four former Smoke files contained 13,411 lines; scheduler support contained 6,011. These are organized by behavior/responsibility.
- Literal source/script contains calls: 520 → 515. Unique safety guards remain.

## Completed checks

- Baseline affected run: 412 tests, 403 passed, 8 failed, 1 skipped; sum of case times 30.556 seconds.
- Shared-helper batch: 204 tests, 196 passed and the same 8 failures; no result drift.
- Four split suites: 253 tests passed.
- Split suites plus scheduler qualification: 299 tests, 298 passed, 1 performance skip.
- Source-check batch: 11 tests, 7 passed and the same 4 Gate 10 failures.
- Original qualification failures require branch feat/v0.0.2-phase-09; checkout is main.
- Package/process-boundary validation and its self-test passed using an isolated SwiftPM scratch directory.
- scripts/test.sh pr stops before tests because the existing untracked examples/demo/hostwright.yaml is not Manifest v3.

Raw build/test logs, discovered identifiers, the initial working diff, per-case summaries, the complete 253-test move map, and normalized XCTest xUnit files are retained locally in `/tmp/hostwright-test-cleanup/` (temporary, private artifacts). SwiftPM produced native Swift Testing XML; serial XCTest output is recorded in the console logs and normalized separately without changing outcomes.

## Final verification

- Full execution covered all 4,035 discovered tests: **3,929 passed, 95 failed, 11 skipped**. XCTest ran 3,974 cases (3,868 passed); Swift Testing ran 61 cases, all passed. The 95 failing XCTest cases produced 387 reported failures, including 114 unexpected errors.
- Every one of the 412 cases recorded before editing has the same result after cleanup: 403 passed, the same eight failed, and the same performance cell skipped. No missing, added, or outcome-changed identifier.
- Full XCTest elapsed time: 4,147.978 seconds (69m 7.978s). The two isolated release builds passed their reproducibility comparison (2,424.437 seconds). Gate 15 passed all 19 tests (649.864 seconds); its source fingerprints also include 2,343 pre-existing untracked demo files.
- `scripts/integration.sh` passed, including CLI/Control refusal and parity, real files and SQLite, backup/restore/recovery, extension subprocesses, and absence of unintended state writes.
- All five durable-lifecycle sentinels passed. `scripts/test.sh` and its shard filters are unchanged; the discovery set is identical, preserving shard membership.
- Affected qualification support was exercised in the separate helper and scheduler runs before the full suite. Scheduler seeds, scenario counts, independent oracle, artifact formats, and fingerprint rules are unchanged; new source contents invalidate old fingerprints normally. No historical evidence was rewritten.
- Package/process-boundary lint and its self-test passed. Documentation links passed (351 references). `git diff --check` passed.

### Full-run failures and limits

| Category | Failing cases | Evidence |
| --- | ---: | --- |
| Phase 09 Gates 2, 5–10 branch requirements | 21 | Require `feat/v0.0.2-phase-09`; current checkout is `main`. Eight of these were reproduced before editing. |
| Phase 09 Gates 13–14 invocation checks | 40 | Test script is outside its invoking repository; preparation fails before evidence files exist. |
| Phase 09 Gate 16 and router path checks | 26 | Protected or unexpected repository path is refused. |
| Core security-documentation assertion | 1 | Existing `SECURITY.md` edit removed an expected phrase; its diff exactly matches the pre-cleanup diff. |
| Manifest corpus checks | 2 | Existing untracked demo uses Manifest v2 and omits explicit CPU/memory requests and limits. |
| Release documentation validators | 5 | Copied documentation/example snapshots fail the current-truth validator, which rejects the existing demo manifest. |

The additional 87 failures were first observed in the full run, outside the targeted baseline. Their test files and relevant production/scripts are unchanged from the captured starting contents; they are not presented as failures reproduced before editing. The PR wrapper also stops at the same demo-manifest validation before running its test stages.

Eleven configured skips remain: six attended Apple CLI/network/permission cells, one official etcd artifact cell, one live registry cell, two attended Tahoe/helper cells, and the opt-in scheduler performance cell. Their required environments or opt-in inputs were not supplied. No live or signed-release qualification evidence was produced by this cleanup.

### Affected suite timings

Values are sums of individual case durations, in seconds, for exactly the same test identifiers. The after values come from the full run. These are single-run observations, not a performance benchmark. `P/F/S` means passed/failed/skipped; outcomes are identical before and after.

| Suite | Cases | Before | After | P/F/S |
| --- | ---: | ---: | ---: | --- |
| BenchmarkCommandTests | 12 | 0.032 | 0.022 | 12/0/0 |
| CLIFileErrorAndRecoveryTests | 9 | 0.419 | 0.366 | 9/0/0 |
| HostwrightCLITests | 95 | 6.270 | 5.761 | 95/0/0 |
| TeamWorkflowCLITests | 9 | 0.564 | 0.535 | 9/0/0 |
| CLIControlProductionRoutingTests | 4 | 0.323 | 0.440 | 4/0/0 |
| HostwrightManifestTests | 40 | 0.103 | 0.100 | 40/0/0 |
| OCIReferrerDiscoveryTests | 8 | 0.001 | 0.001 | 8/0/0 |
| OCIReferrerFetchTests | 4 | 0.023 | 0.022 | 4/0/0 |
| RegistryAuthorizedRequestTests | 4 | 0.000 | 0.000 | 4/0/0 |
| HostwrightRuntimeTests | 78 | 2.176 | 2.476 | 78/0/0 |
| Phase10SchedulerQualificationTests | 46 | 7.313 | 6.319 | 45/0/1 |
| AuditSchemaV19MigrationTests | 2 | 0.184 | 0.135 | 2/0/0 |
| HostwrightStateTests | 40 | 2.608 | 2.480 | 40/0/0 |
| Phase09Gate05QualificationHarnessTests | 6 | 2.780 | 0.916 | 4/2/0 |
| Phase09Gate06QualificationHarnessTests | 6 | 0.975 | 0.919 | 4/2/0 |
| Phase09Gate10QualificationHarnessTests | 7 | 1.421 | 1.323 | 3/4/0 |
| PluginSchemaV21MigrationTests | 2 | 0.158 | 0.142 | 2/0/0 |
| RBACSchemaV20MigrationTests | 3 | 0.233 | 0.218 | 3/0/0 |
| SchedulerSchemaV22MigrationTests | 5 | 0.264 | 0.250 | 5/0/0 |
| StateUpgradeTests | 32 | 4.709 | 4.535 | 32/0/0 |
| **Total** | **412** | **30.556** | **26.960** | **403/8/1** |

## Focused pruning — 2026-09-22

Removed one fully redundant test and consolidated three parser tests into four named cases. All original parser inputs, error-type checks, secret absence checks, and diagnostic assertions remain; the fixture is retained unchanged. Each named case invokes the parser independently. No production changes.

| Removed identifier | Retained replacement |
| --- | --- |
| `HostwrightCoreTests/testSecureProcessExecutionTruthIsDocumentedAndFoundationProcessIsAbsent` | `HostwrightCoreTests/testSecureProcessExecutionTruthUsesOnlyTheSecureBoundary`: identical two documentation checks plus a broader scan banning both qualified and unqualified `Process(...)` calls. |
| `HostwrightRuntimeTests/testAppleContainerParserFailsClosedForUnsupportedRealJSONShapesWithRedaction` | `testAppleContainerParserFailsClosedForMalformedOutputWithRedaction`: named cases `unsupported root with secret fields` and `unsupported list item`. |
| `HostwrightRuntimeTests/testAppleContainerParserFailsClosedForRedactionFixture` | Same retained parser test: named case `fixture with embedded secret text`; still reads the original fixture. |

The original malformed-text case also remains. Table failures identify the scenario, and JSON secret fields and embedded text secrets remain distinct cases.

Nine source assertions were logically implied by stronger assertions in the same contiguous block. Each removal is mapped below; no unique prohibited-operation guard was removed.

| File | Removed substring assertion | Retained substring assertion |
| --- | --- | --- |
| Phase09Gate11QualificationHarnessTests.swift | `XCTAssertTrue(source.contains("$root/active-run-v1"))` | `XCTAssertTrue(source.contains("mkdir \"$root/active-run-v1\""))` |
| Phase09Gate08QualificationHarnessTests.swift | `XCTAssertTrue(source.contains("record_keychain_item"))` | `XCTAssertTrue(source.contains("record_keychain_items"))` |
| Phase09Gate10QualificationHarnessTests.swift | `XCTAssertTrue(source.contains("I"))` | `XCTAssertTrue(source.contains("WasmKitWASI"))` |
| Phase09Gate10QualificationHarnessTests.swift | `XCTAssertTrue(source.contains("S"))` | `XCTAssertTrue(source.contains("WasmKitWASI"))` |
| Phase09Gate10QualificationHarnessTests.swift | `XCTAssertTrue(source.contains("WasmKit"))` | `XCTAssertTrue(source.contains("WasmKitWASI"))` |
| Phase09Gate10QualificationHarnessTests.swift | `XCTAssertTrue(source.contains("cleanup"))` | `XCTAssertTrue(source.contains("identity changed; cleanup is refused"))` |
| Phase09Gate09QualificationHarnessTests.swift | `XCTAssertTrue(source.contains("for n in 1 2 3 4 5 6"))` | `XCTAssertTrue(source.contains("for n in 1 2 3 4 5 6"))` |
| Phase09Gate09QualificationHarnessTests.swift | `XCTAssertTrue(source.contains("codeIdentity(at:"))` | `XCTAssertTrue(source.contains("let ownerIdentity = try clientPath.map { try codeIdentity(at: $0) } ?? qualificationIdentity"))` |
| Phase03QualificationScriptTests.swift | `XCTAssertTrue(source.contains("--prior-helper-bin"))` | `XCTAssertTrue(source.contains("stale-helper requires --prior-helper-bin"))` |

Verification: 152 affected tests ran in 19.829 seconds: 139 passed and 13 failed with exactly the same per-test outcomes as the previous full run. The failures are the existing Core documentation mismatch and Gate 8/9/10 branch requirements. Discovery changed from 4,035 to 4,032; the three missing identifiers are exactly those mapped above, with no added identifiers. `git diff --check` passed.

This pass removes 53 additional Swift test lines (248,668 → 248,615), for a total reduction of 116 lines from the original baseline. It is a narrow, proven pruning pass, not evidence that most remaining tests are unnecessary. No new full-suite run was made after this follow-up. Logs, pre-edit file copies, normalized XCTest XML, assertion mappings, and outcome comparisons are retained locally in `/tmp/hostwright-test-prune/`.
