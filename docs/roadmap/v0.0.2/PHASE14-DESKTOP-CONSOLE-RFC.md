# Phase 14 native desktop operations console

Status: implemented release contract for #258–#262; final device qualification and verification of #258/#262 remain pending.

## Product boundary

The app is a native macOS SwiftUI operations console. It is a presentation and reviewed-lifecycle client of the protocol 2.2 Unix-socket Control API. It does not embed runtime reconciliation, state-database access, or authorization policy. The model uses `PersistentControlClient` for secure socket discovery, peer validation, authentication handshakes, bounded unary deadlines, request cancellation, and stream flow control.

The first usable surface is:

- daemon lifecycle health through the existing `daemon status --output json` control route;
- the configured daemon project/service observation through the existing `status` control operation;
- filtered bounded event streams with cursor-aware acknowledgements;
- finite service log streams with cursor-aware acknowledgements and cancellation;
- dry-run previews for `up`, `down`, and `restart`, followed by confirmation bound to the exact plan hash and selected manifest;
- reconnect/backoff state that never hides unavailable or redacted failures.

The desktop sends the same classified lifecycle route used by the CLI. Duplicate preview or confirmation clicks are ignored while a request is active. Closing the review, explicit cancellation, disconnect, manifest replacement, or reconnect invalidates the review and closes the request socket so the daemon's connection-scoped cancellation reaches the lifecycle coordinator. A late response is fenced by the request UUID and cannot update the new connection state.

The daemon bootstrap discovers the desktop executable only beside the trusted CLI payload, validates its exact static code signature, and declares or rotates that identity in the same installed trust domain. The desktop receives the built-in global `operator` role, which includes observation and reviewed lifecycle execution without owner, security-administration, or maintenance authority. A missing desktop remains compatible with older payload layouts; an invalid or mismatched desktop fails bootstrap before identity mutation.

Team, cloud, MDM, multi-Mac, Kubernetes, accelerator, and automatic in-app update workflows remain outside this release.

## UI direction

Use `NavigationSplitView` with dense project/service tables, an operational detail inspector, event timeline, and log stream. The visual language is native macOS: system SF Pro, SF Mono for log payloads, semantic colors plus text/icon cues, SF Symbols, 4/8-point spacing, 6-point control radii, separators and materials instead of generic cards, no gradients, and no decorative dashboard filler. Controls expose keyboard and VoiceOver labels/identifiers. Motion observes the system reduce-motion setting. Scene storage retains selection per window.

## Packaging and installation

The release builder includes `hostwright-desktop` in both isolated release builds and assembles it as `libexec/hostwright/Hostwright.app` under the managed prefix. The bundle identifier is `dev.hostwright.desktop`; its version is generated from the exact package version. The unsigned developer lane applies a deterministic ad-hoc seal so two-build payload comparison includes the complete bundle. The trusted lane replaces that seal with a hardened-runtime Developer ID signature, verifies the nested executable and bundle, notarizes the archive and package, and records every bundle file in the payload manifest, SBOM, provenance, checksums, installed ownership, rollback, repair, and uninstall sets.

After a standard `/usr/local` package install, launch the app with:

```bash
open /usr/local/libexec/hostwright/Hostwright.app
```

Automatic in-app updates are deferred. Upgrade, one-generation rollback, repair, and uninstall use `hostwright-dist`. Upgrade, rollback, and uninstall refuse modified or unmanaged payloads before mutation. Exact-version-and-source repair restores missing or content-corrupted owned regular files and refuses unsafe or unmanaged filesystem entries, as specified in [Installed Distribution Lifecycle](../../reference/installed-lifecycle.md).

## Evidence boundary

Unit and integration gates cover strict plan/result decoding, exact route binding, stale confirmation, duplicate clicks, explicit cancellation, disconnect cancellation, accessibility identifiers, action-catalog parity, deterministic app assembly, and ownership-scoped distribution lifecycle. Release qualification additionally retains standard and narrow-window snapshots, live authenticated lifecycle evidence, signed/notarized bundle verification, and clean-VM install, reboot, upgrade, rollback, repair, and uninstall evidence bound to the tested source and artifact hashes.

Current qualification uses source `b969a32caaa250f81b75fd6ced34d42e34d7b855` (tree `408f1a5e96d75e7e64da6358c71b770bb3f29b25`), authenticated [runtime 37160477208 attempt 1](https://github.com/hostwright/hostwright/actions/runs/37160477208/attempts/1), and accepted [signing 37170124704 attempt 1](https://github.com/hostwright/hostwright/actions/runs/37170124704/attempts/1). [Current source support](../../evidence/phase14-b969a32c/source-support/CURRENT.md) keeps these measurements separate from historical CD, M, and N evidence and from a later documentation-storage commit.

The [selected unit report](../../evidence/phase14-b969a32c/unit-contract/README.md) records 70 passed methods in five suites. The enclosing fresh XCTest lane records 3,460 cases: 3,450 passed, 10 disclosed skips, and zero failures; Swift Testing records 61 tests in six suites. All 439 warning lines and skip reasons remain disclosed. The [signed distribution stage](../../evidence/phase14-b969a32c/distribution-stage/README.md) records 13 stage checks and 173 command records, with 33 local verification commands and seven authenticated subjects. These separate scopes are not combined into a test total.

Ten native physical CLI cycles have passed: 40 confirmed up/restart/down/remove actions with actual guest, ownership, reservation, and exact Remove-absence proof. Device-report export, 15 authenticated native GUI checks, nine package-only macOS VM cases, independent scoped security assessment, and final installed-device cleanup remain pending. No GUI, VM, cleanup, or issue-closure pass follows from source, unit, signing, or CLI-cycle completion.

The [reduced local release decision](../../design/adr-0015-reduced-local-release.md) retains the deferred scope. Phase 15 whole-release soak, fuzz/corpus, sanitizer, RC/GA, and publication gates remain separate; this checkpoint does not claim them passed.
