# Beta Readiness

> **Historical phase record:** the active release ladder is `0.0.2-dev` → clean `v0.0.2-rc.*` qualification → `v0.0.2`. The current gates are defined in `docs/release/RELEASE_PROCESS.md` and the v0.0.2 roadmap.

Status: Phase 39 beta readiness gate. No beta tag, GitHub Release, binary artifact, installer, support promise, production-readiness claim, or version bump is approved by this document.

Phase 39 defines what must be true before Hostwright can move from alpha to beta. It is a checklist and public-claim guard, not a release action.

## Beta Scope Decision

The next beta can remain source-only unless a separate maintainer-approved distribution issue satisfies `docs/release/distribution-readiness.md`.

Beta readiness is about stability, evidence, and honest docs for the current local Apple silicon scope. It does not require v1.0 readiness, production support, binary installers, cloud behavior, Kubernetes/CRI/Docker API compatibility, multi-host orchestration, tunnels, DNS integration, accelerator support, or GUI implementation.

## Required Evidence Before Any Beta Tag

| Area | Beta gate | Current Phase 39 status |
| --- | --- | --- |
| Source install | Clean checkout from the intended `v*` tag builds, lists tests, runs tests, prints `hostwright --version`, and runs `hostwright doctor`. | Required before tag. |
| Hosted CI | GitHub CI passes on the beta-readiness or release PR. | Required before tag. |
| Local full gate | `swift build`, `swift test list`, `swift test`, `scripts/grep-orchard.sh .`, `scripts/test.sh`, and `scripts/lint.sh` pass. | Required before tag. |
| Runtime proof | Any live Apple container proof uses disposable Hostwright-owned resources, existing local images only, explicit state paths, no image pull, and exact cleanup. If a safe live proof cannot run, the blocker is recorded. | Required or explicitly blocked before tag. |
| Docs alignment | README, install, CLI, compatibility, limitations, release notes, security/safety, release process, requirements, and acceptance matrix agree. | Required before tag. |
| Examples | Checked-in examples validate and plan, and docs say examples are not full Compose parity or multi-action apply proof. | Required before tag. |
| State upgrade | Migration checksum, future-version, corrupt, locked, idempotent, and explicit read/migrate tests pass. Downgrade remains documented as manual policy, not automatic conversion. | Required before tag. |
| Security | Redaction, secret-reference, diagnostics, cleanup, runtime, team, extension, and governance boundaries remain documented and tested. | Required before tag. |
| Operations | Status, logs, events, diagnostics, recovery, daemon foreground loop, health results, restart-state gates, managed restart, and cleanup behavior have test coverage and current docs. | Required before tag. |
| Telemetry | Local-only telemetry policy remains true: no upload, hosted diagnostics, website analytics, external telemetry, or automatic bundle sharing. | Required before tag. |
| Support policy | Security reporting, contribution flow, review triggers, and support boundaries are explicit. No support SLA is implied. | Required before tag. |

## Blockers Before Beta

Beta must not be tagged while any of these are unresolved:

- local or hosted verification failures;
- unreviewed release-blocker findings;
- docs that claim production readiness, broad compatibility, or unsupported runtime behavior;
- missing clean-checkout source install proof from the intended beta tag;
- missing release notes and limitations review for the intended beta tag;
- unsafe live proof evidence, image pulls, non-disposable resources, or unowned cleanup;
- raw secret values in examples, docs, state, diagnostics, events, logs, or fixtures;
- undocumented or unsafe default state path, direct Apple container shell-out outside `HostwrightRuntime`, or SQLite access outside `HostwrightState`;
- unclear upgrade, downgrade, backup, restore, or state-locking operator guidance;
- unsupported public claims about binaries, installers, Homebrew, signing, notarization, SBOM, provenance, performance numbers, capacity, cloud, tunnels, DNS, GPU/ANE/Metal/Core ML/MLX, Kubernetes, CRI, Docker API, Compose parity, multi-host, or GUI behavior.

## Deferrable Past Beta

These are not beta blockers if docs keep them explicit as unsupported, deferred, rejected, or research-only:

- binary archives, installer packages, Homebrew, signing, notarization, SBOM, and provenance;
- production readiness and support SLA;
- v1.0 release readiness;
- website frontend implementation;
- GUI or local control-surface implementation;
- cloud control plane, hosted diagnostics, external telemetry, tunnels, DNS, and public exposure management;
- Kubernetes, CRI, Docker API, Testcontainers, and full Compose parity;
- multi-host orchestration, remote placement, scheduler API, and state replication;
- GPU/ANE/Metal/Core ML/MLX, PyTorch MPS, host-native accelerator helpers, and accelerator-aware scheduling;
- automatic rollback, broad lifecycle management, image cleanup, volume cleanup, unmanaged cleanup, aggressive restart loops, and unattended daemon mutation;
- performance benchmark numbers and production capacity guidance.

## Release Notes And Public Claim Audit

Before a beta tag, public docs must say:

- Hostwright is beta only after the beta tag exists and release notes are published.
- The beta remains scoped to one local Apple silicon Mac unless compatibility docs change with evidence.
- Runtime mutation remains limited to the documented `apply` and `cleanup` gates.
- Installation remains source-only unless distribution readiness evidence exists.
- Limitations are part of the release, not a footnote.

Public docs must not use wording that presents any of these as current support:

- production readiness;
- Kubernetes, CRI, Docker API, full Compose parity, cloud, tunnels, DNS, GPU, ANE, Metal, Core ML, MLX, multi-host, or GUI behavior;
- binary downloads, installers, Homebrew, signing, notarization, SBOM, provenance, support SLA, hosted diagnostics, external telemetry, performance numbers, or capacity guarantees.

## Clean-Checkout Smoke

For the intended beta tag or release branch, run from a fresh checkout:

```bash
swift build
swift test list || swift test --list-tests
swift test
swift run hostwright --version
swift run hostwright doctor
swift run hostwright validate examples/single-service/hostwright.yaml
swift run hostwright plan examples/single-service/hostwright.yaml
```

If live Apple container proof is approved for that release run, it must use only disposable Hostwright-owned resources, explicit state paths, no image pull, and exact cleanup.

## Upgrade, Downgrade, Backup, And Restore

Beta requires current upgrade-safety tests and docs to pass. Automatic downgrade conversion is not implemented; before an upgrade, operators create a verified managed backup with `hostwright state backup`. Raw copying of a live SQLite file or its sidecars is not a supported backup or downgrade procedure.

Before a beta tag, release notes must link the state-store backup/restore guidance and say whether the beta contains a schema change.

## Maintainer Decision Checklist

Before tagging beta, the maintainer should be able to answer:

- What current behavior is supported by tests?
- What runtime mutation is still impossible or intentionally blocked?
- Which blockers remain open?
- Which items are deferred past beta?
- Which docs prove source install, compatibility, limitations, security, telemetry, support, and release truth?
- Which exact commit and tag are being released?

If any answer is missing, beta is not ready.
