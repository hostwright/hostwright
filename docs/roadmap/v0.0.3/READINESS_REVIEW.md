# v0.0.3 readiness review

Date: 2026-11-20. Base: `main` at `5eeebbe3` (#454).

> **Superseded in part.** Section 2a (whole-project placement) and the issue list in section 5 are replaced by [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md). The maintainer chose full cross-Mac networking for v0.0.3. The measurements in sections 1–4 still stand.

This review answers three questions before v0.0.3 work starts:

1. Why is CI slow, and why do release pipelines fail late?
2. Can the existing cluster code carry a two-Mac release?
3. Which tests cost more than they protect?

Scope: CI and pipeline timing, the cluster module (doc comments, type surface, restored tests), a test-suite survey, and size and import stats. The 365k lines of single-Mac modules (State, CLI, Runtime, Scheduler and the rest) were **not** reviewed for correctness or quality.

## Summary

- **PR CI is mostly compile time.** The required `test` check runs about 35 minutes. About 22 of them are two single-threaded debug builds with no cache. The XCTest run takes about 12 minutes, serially.
- **"Hours, then fail" is the release pipelines.** The trusted release stage averages 161 minutes. 66 of them run `scripts/test.sh full`, which repeats everything PR CI already ran and adds the qualification shards. Runtime ingredient runs failed at 68, 122, and 124 minutes. Two of those were terminated (exit 143) at about two hours, which matches the 120-minute step timeouts.
- **The cluster code is a tested contract layer, not a working cluster.** All 104 deleted cluster tests still compile against today's code with one test-only fix. Run together with the one current Keychain test (105 in total), 103 pass, 1 needs a real etcd archive, and 1 fails on fixture loading. There is no network transport, no executor, and no store for membership, lease, or fence state; only certificates persist, to the Keychain. Nothing outside the module calls it.
- **etcd is not load-bearing.** Lease, fence, and replicated-state types are pure checks over a caller-supplied durable store. A single control Mac backed by SQLite can drive them, which fits the two-node, $60 proof.
- **v0.0.2 effort went to ceremony.** Of the 337 commits since 2026-09-01, 137 (41%) have subjects that mention release, qualification, provenance, or similar terms (a keyword match), and 100 (30%) touch only docs.

## 1. CI and release pipelines

### Measurements

PR CI for #450 (run `44457444165`):

| Phase of required `test` | Time |
|---|---|
| Cheap checks (python, lint, governance) | under 1 min |
| `swift build --jobs 1` | 1039 s (17.3 min) |
| Test bundle build | 261 s (4.4 min) |
| XCTest, 379 suites, serial | 11.7 min |
| Swift Testing, 61 tests | 2 s |
| Durable lifecycle sentinels (6 tests) | about 1.2 min |

Other checks on the same PR:

| Check | Required | Time | Notes |
|---|---|---|---|
| `latest-macos-build` | yes | 16–17 min | Full `swift build --jobs 1` again, on macOS 27 |
| `CodeQL (swift,c-cpp)` | no | 34–97 min | 83 min of one run was the traced `swift build --jobs 2` |

The slowest suites:

| Suite | Time |
|---|---|
| `LifecycleLiveDriverTests` | 73 s |
| `DistributionDurableLifecycleTests` | 69 s |
| `TrustedReleaseTests` | 38 s |
| `ReleaseQualificationCLITests` | 31 s |
| `NetworkHelperIngressBrokerTests` | 29 s |
| `MutationCheckpointQualificationScriptTests` | 28 s |

Release pipelines, last 200 runs:

| Workflow | Avg | Max | Failures |
|---|---|---|---|
| Trusted release stage | 161 min | 171 min | 0 |
| Security | 78 min | 126 min | 1 |
| Authenticated runtime ingredients | 46 min | 203 min | 5 |
| CI | 32 min | 59 min | 4 |

Trusted release stage, inside one job:

| Step | Time |
|---|---|
| Run repository regression gate | 66 min |
| Build the trusted release twice and verify | 56 min |
| Stage source bytes and bind evidence | 25 min |
| Download runtime provenance | 9 min |
| Prepare corresponding source | 8 min |

Runtime ingredient failures:

| Run | Failed at | Cause |
|---|---|---|
| 43668338936 | 124 min | Terminated (exit 143), consistent with a 120-minute step timeout |
| 43653625334 | 122 min | Terminated (exit 143), consistent with a 120-minute step timeout |
| 43610865721 | 68 min | `committed runtime inventory differs from freshly verified runtime evidence` |
| 43645302825 | 4 min | `invalid producer binding` |
| 43640876036 | 3 min | `original SDK reuse chain changed` |

### Causes

1. **No build cache.** No workflow restores `.build`, so every job compiles about 365k lines of Swift from nothing.
2. **One compile job.** `--jobs 1` appears in `scripts/test.sh` (lines 27, 31, 53, 62) and `ci.yml:35`. No commit message or doc gives a reason, so it may be a memory guard or leftover caution. Measure before changing it.
3. **Serial XCTest.** `swift test` runs without `--parallel`. #453 (shared Keychain lock) shows that some suites share process-wide state, so parallel runs need a suite audit first.
4. **Duplicate full builds.** For one commit, `latest-macos-build`, `test`, and CodeQL Swift each compile the whole package.
5. **Superseded runs keep going.** `ci.yml` has no `concurrency` group. `security.yml` does.
6. **Release repeats PR work.** The trusted stage runs `test.sh full` on a commit that already passed `test.sh pr`. Only the qualification shards and `check-docs.sh` are new. The repeat may be deliberate if the protected release context does not trust PR-run results.
7. **Late validation.** Ingredient checks compare fresh evidence with committed inventory only at the end of a long step.

### Fixes, in order

| # | Change | Expected effect | Risk |
|---|---|---|---|
| 1 | Cache `.build` keyed on `Package.resolved`, toolchain version, and OS | Large on PRs touching few modules; measure | Low. SwiftPM rebuilds stale inputs. |
| 2 | Time `--jobs 3` against `--jobs 1` on the runner, and adopt it if memory holds | Up to about 2–3x on compile | Medium (runner memory) |
| 3 | Add `concurrency` with `cancel-in-progress` to `ci.yml` | Frees macOS runners on rapid pushes | Low |
| 4 | Run CodeQL Swift on `main`, weekly, and on PRs that touch Swift or C | Removes 34–97 min of macOS time per PR | Low; it is not required |
| 5 | Trusted release consumes the passing CI result for the same SHA and runs only what PR CI skips (qualification shards, docs check) | Most of the 66 min off each release attempt | Medium; it changes release evidence rules |
| 6 | Run ingredient inventory and binding checks before the long assembly step, and size its timeout to measured runs | Fails in minutes instead of 2 hours | Low |
| 7 | Audit suites for shared state, then run XCTest with `--parallel` | Part of the 11.7 min | Medium; needs the audit |

## 2. Cluster code readiness

### What exists

`Sources/HostwrightCluster` holds 12 files and 12,020 lines. Its own doc comments set the scope:

> "This evaluator does not elect, persist, replicate, contact etcd, authorize a network peer, invoke a provider, execute a mutation, or prove distributed fencing." (`ClusterMutationFence.swift`)

> "Source-only mTLS boundary preparation ... The adapter opens no listener or connection." (`ClusterNodeAgentTransportSecurity.swift`)

The only socket in the module is `AF_UNIX`, for a local node-agent subprocess. etcd runs as a supervised local process reached over HTTP on loopback. Nothing outside `HostwrightCluster` and `HostwrightPodSandbox` imports it. That means the CLI, daemon, scheduler, and desktop app never use it.

### Tests

ADR 0016 removed 104 cluster test methods (7,020 lines) in `1c1ef7b9` on 2026-09-22. Since then the module has had one source commit. Restored into a scratch worktree with the old test-target dependencies (`X509`, the `Fixtures` resources):

- **Compile:** one test expression no longer type-checks in reasonable time on the current compiler: a long `+` string chain in `ClusterControlPlaneLeaseTests.swift:832`. Joining an array fixes it, and only test code changes.
- **Run:** 105 tests in 7.8 s: the 104 restored plus the current `KeychainInteractionTests` method.
  - 103 pass.
  - 1 is skipped because it needs `HOSTWRIGHT_P11_ETCD_ARCHIVE`.
  - 1 fails: `testSupervisorTracksRunningAndFailedHealthForNonEtcdFixture` cannot find the `ManagedEtcdSupervisorFixture.swift` resource. The resource rule is unchanged from September, so this is likely a toolchain change in how SwiftPM treats a `.swift` file under `.process`. A `.copy` rule or a non-`.swift` extension should fix it.

### Verdict per file

| File | Lines | Call | Reason |
|---|---|---|---|
| `ClusterMembership.swift` | 1388 | Reuse | IDs, epochs, join tokens, membership plans, and transitions. Needs a store. |
| `ClusterSession.swift` | 1345 | Reuse | Challenge/proof session authority and handoff |
| `ClusterCertificateLifecycle.swift` | 2830 | Reuse | Real Keychain-backed CA and identity lifecycle with journaled rotation |
| `ClusterCertificateTrust.swift` | 634 | Reuse | X509 trust evaluation |
| `ClusterNodeAgentTransportSecurity.swift` | 304 | Reuse | mTLS configuration for a future listener |
| `ClusterRemoteOperationAdmission.swift` | 344 | Reuse | Admission checks for remote operations |
| `ClusterMutationFence.swift` | 699 | Reuse | Fencing proof checks |
| `ClusterControlPlaneLease.swift` | 644 | Adapt | Lease checks with no store. Back it with a SQLite compare-and-set on the control Mac. |
| `ClusterReplicatedDesiredState.swift` | 726 | Adapt | Snapshot checks. With one control Mac, "replicated" means agent copies, not quorum. |
| `NodeAgentTransport.swift` | 799 | Adapt | Local `AF_UNIX` and subprocess only. Needs a TCP listener and client with the mTLS config above. |
| `ManagedEtcdArtifact.swift` | 1153 | Defer | Not needed for a single control Mac |
| `ManagedEtcdRuntime.swift` | 1087 | Defer | Not needed for a single control Mac |

### What v0.0.3 still has to build

1. A network transport: a TCP listener on the worker and a client on the control Mac, both behind `ClusterNodeAgentTransportSecurity`.
2. Durable state on the control Mac: membership, lease, and fence records in the existing SQLite store, with a schema migration.
3. A remote executor: the worker agent runs the existing local lifecycle path. It must not duplicate it, and every mutation carries the fence proof.
4. Wiring:
   - `hostwright node join | leave | list | cordon | drain`
   - daemon ownership of agent connections
   - scheduler placement across nodes
   - status per node in the CLI and the desktop app

No etcd, no consensus, and no cross-host networking or volumes.

## 2a. Networking and security across Macs

Kubernetes spends most of its complexity here. The cluster module covers only part of it: node-to-control mTLS configuration, certificate lifecycle, session authentication, join tokens, and fencing proofs. Single-Mac networking already exists: project-scoped networks, DNS aliases for services and replicas, ingress, and localhost/LAN/public exposure policy. See `docs/architecture/networking-boundary.md`. Nothing reaches across Macs.

| Kubernetes area | Hostwright today (one Mac) | v0.0.3 | Later |
|---|---|---|---|
| Node identity and mTLS | Certificate lifecycle and trust, not wired | Wire it to the agent transport | — |
| Node authorization (NodeRestriction) | none | A worker can act only on workloads placed on itself | — |
| Join/bootstrap tokens | Contract types | Single-use, expiring, never logged | — |
| Certificate rotation and removal | Rotation journal exists | Short-lived node certificates, retired on `node leave` | Revocation lists |
| Secrets on nodes | Keychain, local only | **Fail closed.** Workloads with secrets are not placed on remote Macs. | Encrypted delivery into the worker Keychain |
| Audit | Local event ledger | Every remote operation is recorded on the control Mac | — |
| Agent exposure | none | The listener is mTLS-only, with no unauthenticated endpoint. A rented Mac restricts it to the control Mac's IP (security group or firewall). | — |
| Pod-to-pod networking (CNI) | Project networks on one Mac | **Not needed.** A whole project is placed on one Mac, so its services never talk across Macs. | Cross-Mac network for one project |
| Service discovery / DNS | Project DNS aliases on one Mac | Unchanged, per Mac | Cross-Mac endpoints |
| Ingress / load balancing | Single-Mac ingress | Per Mac | Across Macs |
| Network policy | Exposure policy on one Mac | Unchanged | Cross-Mac policy |

The key scoping choice: **v0.0.3 places whole projects, not single services.** Different projects can land on different Macs, but each project's services stay together. That removes cross-Mac container networking, the hardest part of the Kubernetes model, from v0.0.3 without weakening any security boundary. Cross-Mac networking is the natural v0.0.4.

## 3. Test suite cleanup plan

There are 224k lines of tests in 39 targets. ADR 0016 already removed 30k lines of deferred-feature tests. The next pass should cut by evidence, not by feel.

### Criteria

A test is a removal candidate when one of these holds:

1. **It asserts prose.** It reads `docs/`, `README`, workflow YAML, or Markdown and fails when wording changes. 21 test files read such paths. The heaviest:
   - `ReleaseQualificationRegistryTests` (16 references)
   - `ReleaseQualificationCLITests` (6)
   - `Phase04ExecutableExamplesTests` (5)
   - `TrustedReleaseTests` (4)
2. **It tests v0.0.2 release ceremony** that no longer runs: historical RC qualification, frozen dev.11/dev.12 bindings, one-off ingredient pins.
3. **It covers code that does not ship and is not on the v0.0.3 path.** Candidates to verify first:
   - `HostwrightExtensionsTests` (43 tests)
   - `HostwrightWASIProvider*Tests` (19)
   - `HostwrightXPCProviderTests` (4)
   - `HostwrightRuntimeConformanceToolTests` (44)
4. **It adds no coverage.** Under per-suite coverage, removing it leaves line and branch coverage unchanged.
5. **It is slow for what it guards.** These move to a nightly job rather than being deleted:
   - `LifecycleLiveDriverTests` (73 s)
   - `DistributionDurableLifecycleTests` (69 s)
   - `TrustedReleaseTests` (38 s)

### Method

1. Run the PR suite once with `--enable-code-coverage` and per-suite timing. Record coverage by module.
2. For each candidate suite, run coverage without it, and record what it alone covers.
3. Produce one TSV row per candidate, in the same format as `docs/devlog/test-suite-deletions.tsv`: identifier, file, disposition (`remove`, `nightly`, `keep`), and the scenario that still covers it.
4. Remove in small PRs, by target. Each PR shows coverage before and after.

Do not remove the cluster tests. Section 2 restores them.

## 4. What made v0.0.2 slow to build

| Signal | Evidence |
|---|---|
| Release ceremony | 137 of 337 commits since 2026-09-01; GA readiness records for rc14 through rc20 in `docs/release/` |
| Docs churn | 100 commits touch only docs. Truth checks (`check-current-truth.py`, roadmap governance) fail PRs when prose drifts. |
| Late feedback | Required CI around 35 min; release attempts around 3 h; failures surface at the end |
| Oversized files | 141 Swift files over 800 lines (now tracked by #454's baseline). The largest is `SchedulerAdmissionRepository.swift` at 4,569 lines. |

For v0.0.3:

- Prove a feature once, with a script, and keep the evidence.
- Do not run release candidates per change.
- Keep docs that describe behavior, and drop docs that re-certify it.

## 5. Proposed v0.0.3 issues

These are not filed yet. Labels follow `priority + type + sprint-N`.

| # | Title | Labels | Depends on |
|---|---|---|---|
| 1 | Cache SwiftPM build output in PR CI | P1, chore, sprint-1 | none |
| 2 | Measure and raise compile parallelism in CI | P1, chore, sprint-1 | 1 |
| 3 | Cancel superseded CI runs | P2, chore, sprint-1 | none |
| 4 | Run CodeQL Swift on main, weekly, and Swift/C PRs only | P2, chore, sprint-1 | none |
| 5 | Reuse the passing CI result in the trusted release stage | P1, chore, sprint-1 | none |
| 6 | Fail fast in runtime ingredient pipelines | P1, fix, sprint-1 | none |
| 7 | Correct the unsupported-scope list in `security-safety.md` | P3, fix, sprint-1 | none |
| 8 | Measure per-suite coverage and time, and produce the removal list | P2, test, sprint-2 | 1 |
| 9 | Remove prose-coupled and release-ceremony tests | P2, test, sprint-2 | 8 |
| 10 | Move slow live and durable suites to a nightly job | P2, test, sprint-2 | 8 |
| 11 | Restore cluster tests and fix fixture packaging | P1, test, sprint-3 | none |
| 12 | Multi-Mac threat model RFC: control, agent, join, secrets, exposure | P1, docs, sprint-3 | none |
| 13 | TCP and mTLS node-agent transport | P1, feat, sprint-3 | 11, 12 |
| 14 | SQLite store for membership, lease, and fence records | P1, feat, sprint-3 | 11 |
| 15 | Single-use, expiring join tokens and short-lived node certificates | P1, feat, sprint-3 | 12, 14 |
| 16 | `hostwright node join, leave, list` with daemon wiring | P1, feat, sprint-3 | 13, 14, 15 |
| 17 | Node authorization: a worker acts only on its own placements | P1, feat, sprint-4 | 16 |
| 18 | Project-level placement across Macs | P1, feat, sprint-4 | 16 |
| 19 | Fenced remote execution through the worker agent | P1, feat, sprint-4 | 16, 17 |
| 20 | Refuse remote placement for workloads with secrets | P1, feat, sprint-4 | 18 |
| 21 | Audit trail for remote operations on the control Mac | P2, feat, sprint-4 | 19 |
| 22 | Cordon and drain | P2, feat, sprint-4 | 18, 19 |
| 23 | Multi-Mac proof script with a local VM rehearsal mode | P1, test, sprint-4 | 18–22 |
| 24 | One-time live proof on a rented bare-metal Mac (budget $60) | P1, test, sprint-5 | 23 |

The original Phase 11 issues (#220–#228) stay closed as `not_planned`. New issues link to them for context.

## Open decisions

1. Should deferred modules still compile on every PR? Today they do: Accelerator, DockerEngine, PodSandbox, WASI, Extensions, and about 17k lines of qualification tools. Moving them to a `main`-only build shortens PR CI, but it lets them rot faster.
2. Can the trusted release stage trust a passing CI run for the same SHA? This changes the release evidence rules in `RELEASE_PROCESS.md`.
3. Rental provider: AWS `mac-m4.metal` (macOS 26 supported) or Scaleway (cheaper, macOS 26 unconfirmed).
4. Is project-level placement acceptable for v0.0.3? It keeps cross-Mac container networking out until v0.0.4.
