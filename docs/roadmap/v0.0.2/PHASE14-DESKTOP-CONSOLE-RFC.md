# Phase 14 native desktop operations console

Status: implementation RFC for #258. This document is intentionally limited to the dependency-safe local client surface available on the phase-09 base.

## Product boundary

The app is a native macOS SwiftUI operations console. It is a read-only presentation client of the existing protocol 2.1 Unix-socket control API. It does not embed runtime reconciliation, state-database access, authorization policy, or daemon lifecycle mutation. The model uses `PersistentControlClient` for secure socket discovery, peer validation, authentication handshakes, bounded unary deadlines, and stream flow control.

The first usable surface is:

- daemon lifecycle health through the existing `daemon status --output json` control route;
- the configured daemon project/service observation through the existing `status` control operation;
- filtered bounded event streams with cursor-aware acknowledgements;
- finite service log streams with cursor-aware acknowledgements and cancellation;
- reconnect/backoff state that never hides unavailable or redacted failures.

Mutations, team/cloud/MDM workflows, and capability claims are intentionally absent until their authorization and parity contracts exist.

## UI direction

Use `NavigationSplitView` with dense project/service tables, an operational detail inspector, event timeline, and log stream. The visual language is native macOS: system SF Pro, SF Mono for log payloads, semantic colors plus text/icon cues, SF Symbols, 4/8-point spacing, 6-point control radii, separators and materials instead of generic cards, no gradients, and no decorative dashboard filler. Controls expose keyboard and VoiceOver labels/identifiers. Motion observes the system reduce-motion setting. Scene storage retains selection per window.

## Boundaries and evidence

The SwiftPM targets provide source-level model and UI-test coverage. A signed `.app`, notarization, live daemon connection, and standard/narrow-window screenshot evidence require an Apple-host packaging/credential boundary and the Phase 08 coordinator's explicit runtime release. Until then, verification must remain CPU-light, focused, and use `--jobs 1`; skipped live evidence is recorded as blocked rather than passing.
