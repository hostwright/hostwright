# Devlog 0028: Stack-File Import

Date: 2026-07-08

## Changed

- Added import-only stack-file conversion through `hostwright import-stack <path>`.
- Added `HostwrightImport` for deterministic conversion, diagnostics, policy reason codes, and manifest rendering.
- Added golden-output, unsupported-field, validation-gate, text CLI, and JSON CLI tests.
- Documented the accepted import subset and the rejected compatibility surface.

## Boundaries

- No Docker Compose parity.
- No runtime compatibility claim.
- No file writes from import.
- No RuntimeAdapter calls.
- No Apple container commands.
- No state reads or writes.
- No registry calls or image pulls.
- No DNS, tunnel, cloud, secrets/configs, named-volume, shell-healthcheck, or lifecycle conversion.
- No release tags or GitHub Releases.
