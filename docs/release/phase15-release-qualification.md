# Phase 15 release qualification

This document describes the additive release-qualification boundary introduced for issues #271, #273, #274, #275, and #279. It is a source-only qualification tool and contract library. It does not close Phase 15 or authorize a release.

## Scope and authority

The committed compatibility truth is intentionally narrow:

| Dimension | Committed values |
| --- | --- |
| Release target | `v0.0.2` |
| macOS | major version `26` |
| Hardware | Apple silicon |
| Architecture | `arm64` |
| Apple container CLI | `1.0.0`, `1.1.0` |
| Containerization framework | `0.35.0` |
| Other clients and platforms | no supported claims in this slice |

The three committed cells require live-runtime, migration/upgrade, security-assessment, and resilience/chaos evidence. The detector verifies that the source contains the released Phase 08 main checkpoint `00f95eaabd105f17f61727d2a9899db919ad3d9f`; this is an ancestry fact, not runtime evidence. The executable still never starts Apple Container, a Hostwright daemon, Docker Desktop, a VM, a signing toolchain, or a public-release action without a future explicit provider and evidence handoff.

The Swift contracts in `Sources/HostwrightReleaseQualification` are normative. [`schemas/hostwright-release-qualification.schema.json`](../../schemas/hostwright-release-qualification.schema.json) is the machine-readable companion schema; unknown fields, future schema versions, malformed values, unsafe paths, and non-canonical JSON fail closed.

## Executable contract

Build and invoke the executable with SwiftPM:

```bash
swift build --jobs 1 --product hostwright-release-qualify
swift run --jobs 1 hostwright-release-qualify plan --root "$PWD"
swift run --jobs 1 hostwright-release-qualify detect --root "$PWD"
```

Commands are bounded and write only stdout/stderr unless an explicit private ledger root is supplied. The fixed subprocess environment sets `GIT_NO_LAZY_FETCH=1`, so Git object reads cannot fetch missing promisor objects from a remote.

| Command | Behavior | Successful output |
| --- | --- | --- |
| `plan` | Detects current source, host, framework, and safely queryable tool facts; validates the committed matrix, registry, and seeded corpus identities; and evaluates exact-commit license-policy readiness when source authority is available. | Canonical environment-dependent plan JSON; unavailable providers, dirty or unavailable source authority, and the intentionally empty license-policy receipt remain `blocked`. |
| `detect` | Reads source, host, framework, and safely queryable tool facts. | Canonical environment and per-cell evaluations. |
| `verify --cell ID` | Detects, evaluates one committed cell, and records a real result. | Evidence JSON. Live/heavy/authority cells are blocked, never simulated as passed. |
| `verify --lane documentation-source-contracts` | Runs committed, size-and-hash-bound validator bytes through bounded Python subprocess stdin against an in-memory snapshot of the exact detected Git commit. | Local-integration evidence with exact snapshot/validator command identities, hashes, and output hashes. Dirty or concurrently changed source remains non-promotable. |
| `verify --lane dependency-lock-integrity` | Reads only the exact commit's regular `Package.swift` and `Package.resolved` blobs through bounded Git object commands, then checks canonical direct declarations and the lockfile's structural schema in process. | Local-integration evidence with real snapshot command hashes; direct pin location/version/revision mismatches fail, unavailable inputs block, and dirty or changed source cannot promote. The 64-hex `originHash` shape is validated but not recomputed. |
| `verify --lane license-policy` | Reads the exact commit's regular direct-pin inputs, canonical policy receipt, and bounded committed license-text blobs through the same Git object reader; it performs no network lookup. | Local-integration evidence for structural policy integrity only. Missing receipts or texts block; malformed, extra, stale, pin-mismatched, size-mismatched, or hash-mismatched receipts fail; dirty or changed source cannot promote. |
| `verify --lane secret-scan` | Reads bounded eligible regular blobs from the exact commit through bounded Git object commands, then scans every selected blob's bytes in process, including BOM-marked UTF-16 LE/BE. | Security-assessment evidence with real snapshot command hashes; high-confidence findings fail without reporting credential contents, unsupported encodings block, and dirty or changed source cannot promote. |
| `status --ledger-root PATH` | Reads an existing private ledger. | Canonical ledger summary. |
| `resume --ledger-root PATH` | Recovers running journals to `interrupted` and reports the summary. | Canonical recovery report. |

`verify` accepts `--ledger-root PATH --run-id ID` to atomically persist one result. The ledger root must be an explicit absolute private directory; the executable does not choose a global default. Exit code `64` is usage, `69` is blocked, `70` is failed, and `75` is stale evidence.

## Evidence and ledger rules

Every evidence record binds:

- the exact source commit and dirty-state digest;
- detected host, framework, and tool facts;
- exactly one required evidence class; a single report cannot satisfy every class in a matrix claim;
- explicit executable, argument, working-directory, timing, exit, truncation, and raw-output hashes for every command;
- the claim identity, execution mode, authority, simulation class, replay key, blockers, failures, and owned artifact paths;
- bounded timestamps and duration.

Only `passed` + `real` evidence from an available clean source tree with no blockers or failures satisfies a required gate. `mock`, `fixture`, `dirty`, `stale`, `unavailable`, `skipped`, `cancelled`, and `blocked` outcomes remain visible but cannot satisfy one.

The private ledger uses `0700` directories, a per-ledger owner record, `0600` canonical journal files, envelope hashes, atomic exclusive temporary publication, interruption recovery, replay/idempotency, conflict detection, and current-environment verification. Artifact cleanup preflights the exact relative path, owner marker, size, and hash; it removes only the recorded artifact and its marker. Unmanaged files are retained.

## Gate registry

The default registry is plan-visible and fail-closed:

| Lane | Local behavior | Current boundary |
| --- | --- | --- |
| Qualification/evidence JSON boundary | Strict canonical decode with accept/reject seeded corpus identities. | Executable locally. |
| Dependency lock integrity | Requires the canonical five exact `Package.swift` declarations and exact direct-pin locations, versions, and revisions in a structurally canonical `Package.resolved`; it validates only the `originHash` field's 64-lowercase-hex shape and does not recompute that hash. | Executable locally; both required inputs must be regular exact-commit blobs. Git snapshot observations and output hashes bind the input, but this is not origin-hash integrity, provenance, or license evidence. |
| License policy | Requires canonical receipts for exactly the five supported direct pins and verifies each receipt's committed regular license-text blob by byte size and SHA-256. | Executable locally and fail-closed. [`contracts/v0.0.2/license-policy.json`](../../contracts/v0.0.2/license-policy.json) intentionally has no entries because reviewed third-party texts and metadata are not committed, so the repository lane remains blocked with the missing identities. This is structural local integrity, not legal advice, a compliance conclusion, or transitive-license completeness. |
| Secret scan | Bounded high-confidence byte-pattern scan over eligible immutable regular blobs from the detected commit, including ASCII patterns in arbitrary bytes and BOM-marked UTF-16 LE/BE, with no secret contents in the report. | Executable locally; validated unrelated symlinks and gitlinks are ignored, unsupported encodings block, Git snapshot observations and output hashes bind the input, and findings remain failures. The base test tree contains intentionally secret-shaped AWS/GitHub fixture strings, so a clean scan result is not assumed. |
| Phase 08 protocol fuzz | Plan only. | Phase 08 authority is released; the lane remains blocked by the absent bounded fuzzing provider and corpus. |
| ASan/TSan | Plan only. | Blocked; no sanitizer provider is wired. |
| Semgrep/SAST | Plan only unless a safe provider is explicitly supplied. | Blocked when unavailable; tool presence alone cannot pass the lane. |
| Documentation source contracts | Securely reads committed `check-doc-links.py` and `check-current-truth.py` bytes once, verifies their exact corpus identities, snapshots the detected commit through trusted bounded Git object reads, and executes the immutable validators only against that in-memory snapshot. | Executable locally. A missing, symlinked, changed, or concurrently replaced validator fails closed; transient working-tree swaps cannot change validator inputs, and persistent source drift yields stale evidence. It does not qualify the separately deployed website, CLI/example quickstarts, screenshots, search, accessibility, or clean-system runtime examples. |

The registry records budgets, exclusions, corpus paths, sizes, and SHA-256 identities. It does not claim 24-hour fuzzing, ASan/TSan execution, an independent assessment, external supply-chain evidence, signing/notarization, or public submission.

The former `--execute-safe-checks` cell option is intentionally rejected. Dependency-lock, license-policy, and secret-scan evidence must be requested through their exact first-class lane IDs so immutable commit inputs, Git command observations, and post-run source checks remain bound to the evidence.

### License-policy receipt contract

`contracts/v0.0.2/license-policy.json` is canonical JSON with exact top-level keys `entries`, `kind`, and `schemaVersion`; `kind` is `hostwright.release-qualification.license-policy` and the only supported schema version is `1`. Unknown keys, non-canonical bytes, duplicate JSON fields, unsorted or duplicate entries, and future versions fail closed.

Each entry is sorted by normalized lowercase SwiftPM identity and binds exactly these fields: `identity`, normalized HTTPS `.git` `location`, exact semantic `version`, lowercase 40-hex `revision`, `licenseExpression`, `licenseTextPath`, `licenseTextSizeBytes`, and lowercase `licenseTextSHA256`. The supported license-text path is exactly `contracts/v0.0.2/dependency-licenses/<identity>/LICENSE.txt`; traversal, alternate spellings, symlinks, gitlinks/submodules, missing blobs, unreferenced blobs, and files outside the bounded size limit are rejected. Failure evidence names only fixed labels, normalized identities, and repository-relative paths; license-text bytes are never included.

The deliberately small accepted SPDX expression set is `Apache-2.0`, `BSD-2-Clause`, `BSD-3-Clause`, and `MIT`. This allowlist only constrains the local receipt parser. It does not determine which license applies, approve a dependency, interpret license terms, establish compatibility, or make a legal/compliance assertion. Adding a receipt requires separately reviewed metadata and the exact full text from the dependency revision already pinned in `Package.resolved`; this lane does not download or infer either one.

## Focused verification

The narrow local check is:

```bash
scripts/phase15-release-qualification.sh
```

It runs `swift package dump-package`, a serial product build, the filtered `HostwrightReleaseQualificationTests` target, canonical plan decoding, the JSON schema parse check, the exact-commit `documentation-source-contracts` lane, and `git diff --check`. The script succeeds only when that required local evidence is clean, `passed`, and free of blockers or failures; dirty or otherwise non-promotable evidence stops the script before its success message. It does not run the repository-wide suite or any live runtime.

Remaining Phase 15 evidence gates include final convergence, long-duration fuzz/soak runs, physical multi-host and hardware qualification, independent security assessment, signing/notarization, trusted GA artifacts, and Homebrew submission.
