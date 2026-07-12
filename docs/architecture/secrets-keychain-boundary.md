# Secrets And Keychain Boundary

Status: Phase 24 local boundary.

Hostwright supports a narrow manifest secret-reference model:

```yaml
secretEnv:
  API_TOKEN: keychain://hostwright.api/api-token
```

The manifest stores a reference label, not a secret value. Plaintext sensitive keys under `env` fail validation. `secretEnv` values must use `keychain://<service>/<account>`, and the same key cannot appear in both `env` and `secretEnv`.

## Execution Boundary

Planning, status, state persistence, diagnostics, events, and errors see only redacted secret-reference metadata. A confirmed create action resolves references immediately before calling `RuntimeAdapter.execute`. If no approved backend resolves the reference, apply fails before mutation.

`MacOSKeychainSecretStore` is a read-only production backend for local generic-password items. It queries an exact service/account pair, excludes synchronizable items, and supplies a `LAContext` with interaction disabled so a CLI process never presents authentication UI. Tests inject `InMemorySecretStore` for deterministic failure contracts and separately exercise the live backend against uniquely named real Keychain items.

The default CLI backend remains unavailable by design. Live macOS Keychain access is not enabled by default in Phase 24; an embedding caller must inject the backend explicitly.

## Live Keychain Gate

The live integration gate creates a unique non-synchronizable generic-password item with `SecItemAdd`, resolves it through `MacOSKeychainSecretStore`, deletes the exact service/account item with `SecItemDelete`, and verifies a second lookup returns `errSecItemNotFound`. A malformed-data case proves non-UTF-8 item data fails without exposing the service, account, or bytes. There is no conditional skip path: unavailable Keychain access, disallowed interaction, or failed cleanup fails the test.

Production code does not create, update, or delete Keychain items. Access groups, synchronizable items, biometric or prompt-gated access control, custom keychain selection, credential sync, and credential upload remain out of scope.

## Persistence Boundary

State rows, events, operations, diagnostics, and rendered plans must not contain resolved secret values. Hostwright also redacts keychain reference labels because service/account names can reveal local context.

## Rejected Paths

- no plaintext secret persistence;
- no secrets in examples beyond reference-shaped placeholders;
- no provider credentials, cloud secret managers, ambient identity, or registry credential storage;
- no mounted secret files, multiline secret payloads, or binary secret blobs;
- no Compose/Kubernetes `secrets:` compatibility.
