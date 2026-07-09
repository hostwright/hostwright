# Compatibility

Hostwright `v0.1.0-alpha.1` is a source-only alpha and is not production ready.

Phase 39 defines beta readiness criteria, but no beta compatibility claim exists until a beta tag is approved and release notes are published.

## Compatibility Matrix

| Area | Supported for `v0.1.0-alpha.1` | Notes |
| --- | --- | --- |
| CPU | Apple silicon only | Intel Macs are outside first alpha scope. |
| macOS | macOS 26 or newer | Older macOS versions are outside first alpha scope. |
| Build system | Swift Package Manager | `Package.swift` declares macOS 26. |
| Swift tools | Swift 6.2+ expected | Local verification used Swift 6.3.3 through full Xcode developer tools. |
| Runtime | Apple container CLI | Required for runtime observation, apply, logs, status, and cleanup. |
| Resource intelligence and benchmark lab | Local host facts plus fixture-backed benchmark report contracts | Doctor reports ProcessInfo-backed hardware/thermal facts and unmeasured benchmark dimensions; Phase 36 benchmark lab parses dry-run/fixture reports only; no capacity guarantee. |
| State | Explicit SQLite database path | No default state path is provided. |
| Artifact | Source only | No binaries, installer packages, Homebrew formula, signing, or notarization. |
| Beta readiness | Checklist only | `docs/release/beta-readiness.md` defines required evidence before any beta tag; it does not create beta support by itself. |

## SwiftPM Platform

```swift
platforms: [.macOS(.v26)]
```

This was locally validated with Swift 6.3.3.

## Runtime Limitation

The package can express macOS 26, but runtime compatibility is not complete. Read-only observation is implemented behind `RuntimeAdapter` for verified Apple container output shapes. Unsupported output still fails closed instead of being guessed.

Runtime mutation remains narrow: create one missing managed service, start one restart-policy-allowed managed service, restart one exact Hostwright-owned running service with fresh unhealthy health state, or delete one exact cleanup-eligible managed container after dry-run token confirmation.

## Resource Intelligence Limitation

`hostwright doctor` can report local host facts such as architecture, macOS major version, physical memory, processor count, and current thermal state. It does not run Apple container commands, measure runtime density, measure boot latency, measure battery behavior, or infer production capacity. Apple container version is present only when supplied by reviewed fixture or injected report data.
