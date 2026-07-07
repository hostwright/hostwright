# Compatibility

Hostwright `v0.1.0-alpha.1` is a source-only alpha and is not production ready.

## Compatibility Matrix

| Area | Supported for `v0.1.0-alpha.1` | Notes |
| --- | --- | --- |
| CPU | Apple silicon only | Intel Macs are outside first alpha scope. |
| macOS | macOS 26 or newer | Older macOS versions are outside first alpha scope. |
| Build system | Swift Package Manager | `Package.swift` declares macOS 26. |
| Swift tools | Swift 6.2+ expected | Local verification used Swift 6.3.2 through full Xcode developer tools. |
| Runtime | Apple container CLI | Required for runtime observation, apply, logs, status, and cleanup. |
| State | Explicit SQLite database path | No default state path is provided. |
| Artifact | Source only | No binaries, installer packages, Homebrew formula, signing, or notarization. |

## SwiftPM Platform

```swift
platforms: [.macOS(.v26)]
```

This was locally validated with Swift 6.3.2.

## Runtime Limitation

The package can express macOS 26, but runtime compatibility is not complete. Read-only observation is implemented behind `RuntimeAdapter` for verified Apple container output shapes. Unsupported output still fails closed instead of being guessed.

Runtime mutation remains narrow: create one missing managed service, start one restart-policy-allowed managed service, restart one exact Hostwright-owned running service with fresh unhealthy health state, or delete one exact cleanup-eligible managed container after dry-run token confirmation.
