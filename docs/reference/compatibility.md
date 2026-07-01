# Compatibility

## First Supported Release Target

- Apple silicon Mac.
- macOS 26 or newer.
- Apple container workloads.

## SwiftPM Platform

This repository uses SwiftPM with:

```swift
platforms: [.macOS(.v26)]
```

This was locally validated with Swift 6.3.2 before creating `Package.swift`.

## Runtime Limitation

The package can express macOS 26, but runtime compatibility is not fully implemented. Phase 5 adds read-only observation infrastructure behind `RuntimeAdapter`, but real Apple container behavior remains unverified unless local output matches the supported parser shape.
