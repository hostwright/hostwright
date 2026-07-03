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

The package can express macOS 26, but runtime compatibility is not complete. Read-only observation is implemented behind `RuntimeAdapter` for verified Apple container output shapes. Unsupported output still fails closed instead of being guessed.
