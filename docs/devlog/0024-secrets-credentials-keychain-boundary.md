# Phase 24: Secrets, Credentials, And Keychain Boundary

## Implementation Plan

- Add a local secret-reference model without widening the manifest into Compose/Kubernetes secrets.
- Keep live macOS Keychain unavailable by default and use a fake backend in tests.
- Resolve references only immediately before confirmed runtime execution.
- Preserve existing redaction and explicit state-path boundaries.

## What Changed

- Added `HostwrightSecrets` with `HostwrightSecretReference`, `SecretStore`, `FakeKeychainSecretStore`, and an unavailable default backend.
- Added `secretEnv` manifest support for `keychain://<service>/<account>` references.
- Rejected plaintext credential-like `env` keys, malformed references, duplicate `env`/`secretEnv` keys, and secret references placed under `env`.
- Resolved secret references through the injected backend before confirmed create execution and rejected unresolved references in the runtime adapter.
- Redacted keychain reference labels in runtime and observability surfaces.

## Boundaries Preserved

- No live Keychain access by default.
- No Keychain prompts.
- No access groups or synchronizable items.
- No credential upload, sync, cloud identity, or registry credential storage.
- No provider integration.
- No Compose/Kubernetes `secrets:` support.
- No runtime mutation expansion.
