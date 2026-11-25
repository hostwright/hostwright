# V3-08 test suite measurements

The disposition ledger records candidates for V3-09 and V3-10 in the historical four-column format. Each row names the scenario to retain or the requirement being retired. The measurements leave the test selectors and all cluster tests in place. [V3-08 ledger](test-suite-deletions.tsv) · [Historical deletion ledger](../../devlog/test-suite-deletions.tsv)

## Baseline

The instrumented baseline used the `46821da5` tree on arm64 macOS 26.6.2 with Swift 6.4 from Xcode 27.0 and Apple LLVM 21. The uninstrumented timings below come from the warm macOS 26 PR job at `c1f07588`. The commits have identical Git trees (`9170b29364f74abf5a5c7fd9e55949d0cc7c7f06`). The warm log records 392 XCTest suite timings, 3,562 XCTest cases including six durable lifecycle sentinels, and five skips. The sum of XCTest suite execution times was 836.124 seconds. The Swift Testing xUnit artifact separately records 61 cases. The whole PR regression step took 18m 42s and also ran the Python, integration, and lint checks. [Warm macOS 26 PR job](https://github.com/hostwright/hostwright/actions/runs/45432907475/job/138582794085)

Measure the two Swift PR invocations with the selectors in the PR test runner. The coverage denominator is the compiler-mapped lines and branch outcomes in checked-in first-party `Sources/` files. Test sources, SwiftPM dependencies and system libraries are excluded. Branch totals include only compiler-emitted outcomes. A dash marks an unavailable branch denominator. [PR test runner](../../../scripts/test.sh)

The instrumented run observed 3,623 test cases across the PR invocations. 3,618 passed and 5 skipped. The fast and sentinel invocations took 533.9s and 76.7s locally. Coverage was 211,246 of 283,180 mapped lines and 71,977 of 107,474 code regions. This Swift coverage build emitted no branch outcomes, and the only first-party C source is a SQLite wrapper with a single call. The omission analysis uses source regions to measure execution within a line. Branch coverage is unavailable in this measurement. The skipped cases require the optional scheduler performance cell, live registry access, attended Tahoe VM inputs, or an official etcd archive.

## Omission measurements

Execute each candidate partition and the complementary PR tests separately with the same instrumented build. The six durable sentinels form their own partition. Compare the assembled partition to a full run of the two original PR selectors. Compare the selected case identifiers and compiler-emitted coverage identities. Include code regions to detect different execution within a source line. A candidate's unique coverage is its observed identities minus the union of all other partitions. For an omission with only shared coverage, the remaining scenario still needs to assert the behavior. A zero delta alone never retires a contract or safety assertion.

The two complete runs matched on case identifiers and outcomes. The canonical run alone hit 8 lines and 5 code regions. The partitioned run alone hit 5 lines and 6 code regions. The omission counts below come from within the partitioned run, which uses one complement for each candidate. Suite totals use the warm job. When only selected cases are shown, the warm total is the sum of those case timings or the suite total minus its separately listed cases.

| Candidate | Cases | Warm XCTest seconds | Unique lines | Unique code regions | Unique branch outcomes | Files with most unique identities |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `LifecycleLiveDriverTests` | 55 | 90.484 | 2206 | 698 | — | `HostwrightCLI/LifecyclePersistedRecoveryDriver.swift`, `HostwrightCLI/LifecycleRecoveryExecution.swift` |
| `TrustedReleaseTests release behavior` | 40 | 1.360 | 881 | 309 | — | `HostwrightDistribution/TrustedReleaseSupport.swift`, `HostwrightDistribution/TrustedReleaseBuilder.swift` |
| `TrustedReleaseTests workflow assertions` | 2 | 0.015 | 0 | 0 | — | — |
| `TrustedReleaseTests real Ruby and Homebrew style` | 1 | 33.687 | 0 | 0 | — | — |
| `ReleaseQualificationCLITests` | 15 | 30.871 | 2200 | 811 | — | `HostwrightReleaseQualification/ReleaseQualificationRegistry.swift`, `HostwrightReleaseQualification/ReleaseQualificationCLI.swift` |
| `Phase04ExecutableExamplesTests manifest behavior` | 4 | 0.023 | 0 | 0 | — | — |
| `Phase04ExecutableExamplesTests README assertions` | 1 | 0.006 | 0 | 0 | — | — |
| `ActivePluginProviderRuntimeTests` | 2 | 0.366 | 75 | 39 | — | `HostwrightExtensions/ActivePluginProviderRuntime.swift` |
| `ExecutableExtensionDocumentTests` | 7 | 0.011 | 22 | 18 | — | `HostwrightExtensions/ExecutableExtensionModels.swift` |
| `HTTPSPluginPackageSourceTests` | 4 | 0.015 | 429 | 209 | — | `HostwrightExtensions/HTTPSPluginPackageSource.swift` |
| `PluginABIContractTests` | 2 | 0.002 | 0 | 0 | — | — |
| `PluginImmutableStoreTests` | 13 | 11.043 | 223 | 119 | — | `HostwrightExtensions/PluginImmutableStore.swift`, `HostwrightState/PluginLifecycleRepository.swift` |
| `PluginProviderHealthCheckerTests` | 1 | 0.002 | 94 | 38 | — | `HostwrightExtensions/PluginProviderHealthChecker.swift` |
| `ReviewedLocalExtensionHostIntegrationTests` | 5 | 3.091 | 341 | 128 | — | `HostwrightExtensions/ExtensionFileSecurity.swift`, `HostwrightExtensions/ReviewedLocalExtensionHost.swift` |
| `SecurePluginPackageTests` | 9 | 6.392 | 46 | 43 | — | `HostwrightExtensions/SecurePluginPackage.swift` |
| `HostwrightWASIProviderSDKTests` | 8 | 0.012 | 224 | 130 | — | `HostwrightWASIProviderSDK/HostwrightWASIProviderSDK.swift` |
| `HostwrightWASIProviderCompatibilityTests` | 1 | 0.001 | 0 | 0 | — | — |
| `HostwrightWASIProviderResilienceTests` | 1 | 0.001 | 0 | 0 | — | — |
| `HostwrightWASIProviderRuntimeTests` | 4 | 0.010 | 122 | 80 | — | `HostwrightWASIProviderRuntime/WASIProviderRuntime.swift`, `HostwrightControlPlane/ProfilePluginContracts.swift` |
| `HostwrightWASIProviderSecurityTests` | 5 | 0.061 | 134 | 59 | — | `HostwrightWASIProviderRuntime/WASIProviderRuntime.swift`, `HostwrightCore/SecureSubprocess.swift` |
| `XPCProviderCodecTests` | 4 | 0.003 | 156 | 64 | — | `HostwrightXPCProvider/XPCProvider.swift` |
| `RuntimeQualificationCommandTests` | 8 | 0.010 | 244 | 106 | — | `HostwrightRuntimeConformanceTool/RuntimeQualificationCommand.swift` |
| `RuntimeQualificationEvidenceTests` | 3 | 0.004 | 53 | 20 | — | `HostwrightRuntimeConformanceTool/RuntimeQualificationEvidence.swift` |
| `RuntimeQualificationMigrationDriverTests` | 5 | 0.206 | 149 | 30 | — | `HostwrightRuntimeConformanceTool/RuntimeQualificationMigrationDriver.swift` |
| `RuntimeQualificationMigrationReportTests` | 3 | 0.004 | 145 | 52 | — | `HostwrightRuntimeConformanceTool/RuntimeQualificationMigrationReport.swift` |
| `RuntimeQualificationProcessControlTests` | 4 | 0.634 | 149 | 67 | — | `HostwrightRuntimeConformanceTool/RuntimeQualificationProcessControl.swift` |
| `RuntimeQualificationRecoveryDriverTests` | 11 | 0.632 | 517 | 171 | — | `HostwrightRuntimeConformanceTool/RuntimeQualificationRecoveryDriver.swift`, `HostwrightCore/SecureExecutable.swift` |
| `RuntimeQualificationRecoveryReportTests` | 6 | 0.004 | 243 | 98 | — | `HostwrightRuntimeConformanceTool/RuntimeQualificationRecoveryReport.swift`, `HostwrightRuntimeConformanceTool/RuntimeQualificationRecoveryDriver.swift` |
| `RuntimeQualificationSDKSeederTests` | 4 | 0.002 | 60 | 38 | — | `HostwrightRuntimeConformanceTool/RuntimeQualificationSDKSeeder.swift` |
| `DistributionDurableLifecycleTests PR sentinels` | 6 | 65.988 | 3447 | 1396 | — | `HostwrightDistribution/DistributionInstalledLifecycle.swift`, `HostwrightDistribution/DistributionAssembler.swift` |

The ledger proposes 1 removal, 1 nightly move, and 31 keeps. The separate release qualification run passed 37 cases in 12.103s of suite execution. Its profile hit 460 lines outside the canonical PR baseline. Retain the existing release qualification lane and keep the remaining durable distribution qualification cases on their current selector. The distribution qualification remainder is outside the PR measurement and has no PR timing or omission claim. The existing native live qualification selectors are also outside the PR baseline.

The Phase 04 README phrase inventory adds no measured first-party line or code region. The proposed removal retires the check that the example READMEs document the dry-run and `--confirm-plan "$PLAN_SHA256"` sequence and omit unsupported `hostwright pull`, `build`, and `load` commands.

The Homebrew style case spent 33.687s in the warm PR job. It is a nightly candidate with 0 unique lines and 0 unique code regions. The retained PR case covers the immutable URL, digest and installed command surface. V3-10 must add a nightly job that runs the real Ruby and Homebrew style case in the same PR that removes the case from PR selection. V3-10 needs a paired timing run before any savings claim.

Keep the six durable PR sentinels, the live-driver suite and the two workflow safety assertions. The durable and live-driver cases guard recovery, mutation and scheduler authority across state transitions. The workflow assertions guard protected tags and credential isolation, which source coverage alone cannot establish.

## Reproduce

Run from the repository root on an arm64 macOS host with Xcode and Homebrew. Use a clean checkout of `46821da5` and a scratch directory outside the checkout. Keep the package lock pinned. Use the SwiftPM binary directory for the same configuration and scratch path throughout.

```bash
evidence="$(mktemp -d "${TMPDIR:-/tmp}/hostwright-v3-08.XXXXXX")"
scratch="$evidence/build"
qualification_filter="$(sed -n "s/^readonly qualification_filter='\(.*\)'$/\1/p" scripts/test.sh)"
sentinel_filter="$(sed -n "s/^readonly durable_lifecycle_sentinel_filter='\(.*\)'$/\1/p" scripts/test.sh)"

swift build --jobs 4 --build-tests --enable-code-coverage --scratch-path "$scratch"
coverage_dir="$(dirname "$(swift test --show-codecov-path --scratch-path "$scratch")")"

record() {
    name="$1"
    shift
    swift test --jobs 4 --skip-build --enable-code-coverage --scratch-path "$scratch" \
        --xunit-output "$evidence/$name.xml" "$@" > "$evidence/$name.log" 2>&1
    cp "$coverage_dir/default.profdata" "$evidence/$name.profdata"
}

record pr-fast --skip "$qualification_filter"
record pr-sentinels --filter "$sentinel_filter"
record qualification-release --filter 'ReleaseQualificationRegistryTests/'
xcrun llvm-profdata merge -sparse -o "$evidence/pr-baseline.profdata" \
    "$evidence/pr-fast.profdata" "$evidence/pr-sentinels.profdata"
```

For each candidate partition, select the exact `Module.Suite/testMethod` identifiers from the PR fast XCTest log. Reuse the instrumented target bundle with `xcrun xctest -XCTest "$comma_separated_case_ids" "$bundle"`. Set `LLVM_PROFILE_FILE` to a separate directory with the pattern `%m-%p.profraw`, then merge that directory’s raw profiles with `llvm-profdata merge -sparse`. This lets each candidate load only its own test bundle. Measure the rest with SwiftPM, skipping the qualification filter and the alternation of all candidate selectors. Reuse the baseline sentinel profile. Compare case identities from the XCTest log and Swift Testing xUnit output, including skipped cases. Match the same target and test names in the uninstrumented job log for per-suite execution time. The workflow retains the compressed PR logs in its test-results artifact.

Use `xcrun llvm-cov export --format=lcov --skip-functions --skip-expansions` with each merged or partition profdata, the instrumented XCTest executables and SwiftPM command products, and `--sources` followed by tracked first-party source paths. Identify instrumented objects by the Mach-O `__llvm_covmap` section. Count positive `DA` identities by repository-relative file and line. Count positive `BRDA` identities by file, line, block and branch. Export LLVM JSON for code-region evidence. Use the positive-count source ranges of code regions, deduplicated by file, start line and column, and end line and column. Treat these as source-region coverage. Group by the first component under `Sources/` for module coverage. Preserve logs, test-result XML, and profdata beside the timing output.

## Instrumented PR baseline by module

| Module | Mapped lines covered | Mapped branch outcomes covered |
| --- | ---: | ---: |
| `HostwrightAccelerator` | 0 / 2321 | — |
| `HostwrightAcceleratorService` | 0 / 11 | — |
| `HostwrightAcceleratorXPC` | 0 / 3120 | — |
| `HostwrightAdmissionQualificationTool` | 0 / 149 | — |
| `HostwrightAuditQualificationTool` | 64 / 173 | — |
| `HostwrightCLI` | 43889 / 56889 | — |
| `HostwrightCluster` | 7174 / 8771 | — |
| `HostwrightCommand` | 0 / 8 | — |
| `HostwrightCommandTransport` | 1725 / 2319 | — |
| `HostwrightContainerizationHelper` | 1799 / 3462 | — |
| `HostwrightControl` | 2592 / 3051 | — |
| `HostwrightControlPlane` | 1455 / 1575 | — |
| `HostwrightControlSecurity` | 474 / 549 | — |
| `HostwrightControlSecurityQualificationTool` | 251 / 1058 | — |
| `HostwrightControlTool` | 0 / 92 | — |
| `HostwrightControlTransport` | 2751 / 3134 | — |
| `HostwrightCore` | 1910 / 2178 | — |
| `HostwrightCriticalFuzzer` | 0 / 89 | — |
| `HostwrightDaemon` | 3935 / 6057 | — |
| `HostwrightDaemonCore` | 4179 / 4783 | — |
| `HostwrightDesktopApp` | 288 / 681 | — |
| `HostwrightDesktopEntry` | 0 / 17 | — |
| `HostwrightDesktopModel` | 2737 / 3346 | — |
| `HostwrightDistribution` | 6148 / 11606 | — |
| `HostwrightDistributionTool` | 0 / 676 | — |
| `HostwrightDockerEngine` | 0 / 1561 | — |
| `HostwrightDockerProxy` | 0 / 83 | — |
| `HostwrightExtensions` | 2205 / 2596 | — |
| `HostwrightHealth` | 2308 / 2854 | — |
| `HostwrightImport` | 1305 / 3471 | — |
| `HostwrightKeychainSupport` | 16 / 16 | — |
| `HostwrightManifest` | 6435 / 7969 | — |
| `HostwrightNetworkHelper` | 0 / 75 | — |
| `HostwrightNetworkHelperCore` | 12592 / 15157 | — |
| `HostwrightNetworkProviders` | 1032 / 1270 | — |
| `HostwrightNetworking` | 2741 / 3020 | — |
| `HostwrightObservability` | 1054 / 1123 | — |
| `HostwrightPodSandbox` | 0 / 2652 | — |
| `HostwrightPodSandboxGuest` | 0 / 49 | — |
| `HostwrightPolicy` | 2493 / 2687 | — |
| `HostwrightProfileQualificationTool` | 0 / 154 | — |
| `HostwrightRBACQualificationTool` | 0 / 104 | — |
| `HostwrightReconciler` | 8175 / 9273 | — |
| `HostwrightRegistry` | 7940 / 9516 | — |
| `HostwrightReleaseQualification` | 4439 / 6191 | — |
| `HostwrightReleaseQualificationTool` | 0 / 35 | — |
| `HostwrightRuntime` | 19219 / 23162 | — |
| `HostwrightRuntimeConformanceTool` | 1649 / 4500 | — |
| `HostwrightSQLiteSupport` | 3 / 3 | — |
| `HostwrightScheduler` | 5235 / 5860 | — |
| `HostwrightSecrets` | 1227 / 1517 | — |
| `HostwrightState` | 37243 / 45661 | — |
| `HostwrightStorage` | 11912 / 13768 | — |
| `HostwrightStorageHelper` | 0 / 120 | — |
| `HostwrightStorageProviderHelper` | 0 / 30 | — |
| `HostwrightStreamQualificationTool` | 0 / 1123 | — |
| `HostwrightWASIAdversarialProvider` | 0 / 30 | — |
| `HostwrightWASIProviderQualificationTool` | 0 / 133 | — |
| `HostwrightWASIProviderRuntime` | 259 / 348 | — |
| `HostwrightWASIProviderSDK` | 224 / 280 | — |
| `HostwrightWASIProviderWorker` | 0 / 62 | — |
| `HostwrightWASIReferenceProvider` | 0 / 33 | — |
| `HostwrightXPCProvider` | 169 / 481 | — |
| `HostwrightXPCProviderQualificationTool` | 0 / 83 | — |
| `HostwrightXPCProviderService` | 0 / 15 | — |
| **Total** | **211,246 / 283,180** | — |
