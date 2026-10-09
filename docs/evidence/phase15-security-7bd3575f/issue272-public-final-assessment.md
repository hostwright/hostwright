# Independent source-security assessment — issue 272

**Passed for the exact reviewed source.** Reviewer `rc6_review` completed the focused shipped-boundary review and independently verified the fresh source evidence. No unresolved P0/P1 security defect or release-blocking security finding remains in this reviewed scope. This is not exhaustive security certification.

Source: `7bd3575fff351fd4f1b20c694619457ded99a1a6`; tree `0e75bd167d2f01e1efafa24355bc8fc5e3a35f79`; version `0.0.2-rc.7`; worktree clean before and after execution and independent verification.

The source-security acceptance criteria of [issue 272](https://github.com/hostwright/hostwright/issues/272) are satisfied for this commit. Issue closure still requires the separate final-head CI/merged-source binding and publication of the immutable evidence with the required final marker and `status:verification`. Those are recorded as closure actions, not pending tests. No signed-artifact or release approval is granted.

## Evidence and results

The passive evidence collector actually exited **0** in **368 ms**. It checked clean source snapshots, current tracked bytes, reviewed hashes, command logs, compiled test inventory, test-binary hashes and raw case outcomes. It independently reconciled every selected case, rather than trusting a summary count.

| Fresh execution | Actual result |
| --- | --- |
| Focused Swift security classes/modules | **344 passed**, 0 failed, 0 omitted, 0 skipped: 301 XCTest + 43 Swift Testing |
| Seven named Python regression scripts | **96 passed**, including 10 shell/doctor tests |
| Real Docker proxy process cases | **5 passed**: help, idle SIGTERM/SIGINT, partial-request SIGTERM/SIGINT |
| Complete enforced integration | **Exit 0**, 24.388940 seconds; binary and canonical contract both `0.0.2-rc.7` |

The schema report counts 445 actual test cases; the additional integration command is recorded separately. Environment: macOS 26.6.2 build 25G83, arm64, Mac16,8 / M4 Pro, 25,769,803,776 memory bytes, Xcode 26.6, Swift 6.3.3, system Bash 3.2.57. Hosted current-compiler CI is recorded in the separate merge binding.

The [schema report](issue272-public-final-assessment.json) and [detailed companion](issue272-public-final-companion.json) retain exact hashes, all per-selector outcomes, individual scan dispositions and limits. The original and sanitized evidence hashes are linked by the publication manifest; embedded original log hashes continue to identify the retained private originals.

## Review coverage

The review covers shipped authentication/authorization, persistent Control sessions and peer identity, privileged-helper and extension containment, executable/resource ownership, desktop confirmation, parser/protocol entrypoints, state and mutation authority, distribution and qualification evidence integrity.

The exact source map contains 127 entries with selected ranges or reviewed deltas; this does not claim whole-file or whole-repository coverage. Of the 48 files examined during the RC7 extension, 47 remain byte-identical. The trusted-release workflow changed only by the reviewed explicit assertion guards. Prior review is reused only for exact matching bytes or separately reviewed changes.

| Selected class or module | Passed |
| --- | --- |
| `AppleContainerCodecTests` | 10 |
| `ContainerizationHelperProtocolTests` | 12 |
| `ControlFrameCodecTests` | 8 |
| `ControlIdentityBootstrapTransactionTests` | 3 |
| `ControlIdentitySecurityAdapterTests` | 7 |
| `ControlRequestRepositoryTests` | 15 |
| `DaemonLocalLifecycleAuthorityTests` | 17 |
| `DesktopOperationsModelTests` | 38 |
| `HostwrightImportTests` (module) | 22 |
| `LifecycleCLIOptionsTests` | 3 |
| `LifecycleCommandRunnerTests` | 40 |
| `LifecycleSchedulerEffectFreshnessTests` | 3 |
| `LocalPathsTests` | 5 |
| `ManifestV2StrictTests` | 26 |
| `PersistentControlClientTests` | 7 |
| `PersistentControlServerTests` | 17 |
| `ReleaseQualificationCLITests` | 15 |
| `ReleaseQualificationLedgerTests` | 4 |
| `ReleaseQualificationRegistryTests` | 37 |
| `SQLiteHardeningTests` | 9 |
| `SecureExecutableACLTests` | 6 |
| `SecureLocalPathTests` | 13 |
| `SecureSubprocessTests` | 27 |

Every row has zero failed/skipped/missing/unexpected cases. `HostwrightImportTests` is a module selector. The compiled inventory determines expected membership.

## Findings and remediation

- **Initial executable ACL gap (P2): resolved.** Existing access-grant restrictions now apply to executable/working-directory descriptors and lexical/canonical ancestors. All six ACL cases and related path/subprocess cases pass. The old ctime rejection of post-capture changes is distinguished from the original initial-resolution gap. No root escalation was established.
- **macOS shell assertion failure (P1, evidence integrity): resolved.** Mandatory compound assertions now exit explicitly on system Bash 3.2. Negative actual-shell checks, assertion lint and precise source-doctor expectations pass; the fresh complete integration command exits zero. Intentional predicates remain unchanged. Historical misleading success and subsequent real failures remain preserved.
- **Docker proxy compiler isolation correction: reviewed and locally regressed.** Removing `nonisolated` preserves the synchronous daemon loop and signal cancellation. The fresh source build and five real process cases pass. Final-head hosted compiler results belong to the merge binding.
- **Linux workflow lint exception (P2): resolved.** Every canonical job must specify the exact static Linux runner; dynamic, list, multiline, missing, quoted and inline variants are negatively tested. The authenticated SDK compiler recipe and verifier remain unchanged.
- **Publication identifiers (P2): corrected.** All 44 reviewed derivatives were reconstructed from their private originals. Declared path substitutions changed 25 files. Trailing spaces and tabs were also removed from 67 console lines in two logs; the manifest records each intermediate and final hash. Outcomes, counts, findings and line order remain unchanged.

## Scan assessment

| Scanner | Preserved actual result | Independent disposition |
| --- | --- | --- |
| Gitleaks 8.30.1 | Exit **1**, **16** redacted contexts | Exact prior inspected source contexts match: declarations, PEM parser markers or fixed non-secret qualification identifiers. All individually assessed as false positives. |
| Semgrep 1.176.1 | Exit **0**, zero findings, **32** parser warnings | Warning payloads, spans and source hashes match the retained assessment. Parser-coverage gaps remain explicit. |
| OSV Scanner 2.6.0 | Exit **0**, **18** advisory groups | Exact advisory payloads and corresponding source match. Retained Linux/arm64 producer/package/function evidence supports the limited dispositions; `called=false` alone is never clearance. |

The complete source archive matched every tracked file in the clean snapshot. Retained producer manifest, payload and compiled-package trace were rehashed. Affected HTTP/HTML/IDNA/Windows package paths are absent from the exact reviewed netfilter producer; the DNS group has separate compiled-symbol, CGO and call-path reasoning. This does not clear other programs in a future signed bundle.

The publication secret scan additionally flagged 68 source-file digest values and one generated restore-plan confirmation digest for the deleted test database. Each was inspected without publishing secret values in the review. None was a credential finding.

## Cleanup and limitations

The assessment collector is read-only. Independent post-run observations found the traced integration root absent under both its lexical and canonical path spelling, and no process matching the five exact source-built product paths or that root. Proxy cases require bounded child exit and socket removal. Other test-owned teardown is limited to the reviewed implementations. No system-wide or all-test temporary-resource baseline is claimed. Product hashes were observed after execution; no pre-execution capture is invented.

`RC7-HARDENING-001` remains P3 hardening: the Apple provider JSON scanner lacks explicit recursion-depth accounting. Existing isolated malformed-input evidence supports a parser availability concern, but no legitimate workload-controlled production output path, privilege crossing or production exploit was established. Further executable probing stopped after a tool safety limitation; no bypass or repeat probe was performed. Dedicated depth/node rejection remains recommended.

Compose import has no dedicated input-byte limit for arbitrarily large operator-selected local files. This review does not establish bounded memory for that case. Static-analysis warnings remain coverage gaps.

The original long-checkout six-case failure, its path-length diagnosis, and the later full run with 3,533 passes and ten attended skips remain unchanged historical evidence. The full run stays incomplete. Fresh focused results satisfy this issue’s applicable source-security boundary; no skipped or failed required result is relabeled.

Final signed contents/SBOM inventory, installed lifecycle, attended sanitizer/live lanes, Homebrew acceptance and release publication remain separate gates. `qualificationAccepted: false`; `artifactBoundReleaseApproval: false`. Subsequent source changes need appropriate delta review; this result is bound to the exact commit above.
