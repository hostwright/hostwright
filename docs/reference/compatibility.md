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

## Phase 1 Limitation

The package can express macOS 26, but runtime compatibility is not fully implemented. Apple container CLI was not found during local inspection, so runtime behavior remains unverified.

