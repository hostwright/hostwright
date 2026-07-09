# Phase 21: GUI Control Surface Requirements And API Boundary

Phase 21 defines a local control-surface boundary without building a control surface.

## What changed

- Added `docs/architecture/control-surface-api-boundary.md`.
- Documented approved local data surfaces for manifests, plans, apply confirmation, status, logs, events, recovery, cleanup previews, diagnostics, doctor, and errors.
- Defined commands and internals that a control surface must never call directly.
- Added accessibility requirements for keyboard navigation, screen-reader status/error states, focus, confirmation review, and diagnostics sharing.
- Added handoff criteria for a separate design/frontend owner.
- Updated requirements, acceptance, limitations, implementation plan, build status, traceability, and docs guard coverage.

## Safety boundaries

- No GUI code.
- No website implementation.
- No web dashboard or cloud dashboard.
- No daemon API.
- No direct Apple container execution.
- No direct SQLite access.
- No RuntimeAdapter bypass.
- No runtime mutation outside existing Hostwright gates.
- No telemetry upload or hosted diagnostics.
- No release tags or GitHub Releases.
