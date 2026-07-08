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

The default CLI backend is unavailable by design. Tests use `FakeKeychainSecretStore`. Live macOS Keychain access is not enabled by default in Phase 24.

## Future Live Keychain Gate

A live macOS Keychain backend requires separate approval and must remain noninteractive for CLI use. Operations that could trigger authentication UI must fail cleanly instead of prompting. Access groups, synchronizable items, biometric or prompt-gated access control, custom keychain selection, credential sync, and credential upload are out of scope.

## Persistence Boundary

State rows, events, operations, diagnostics, and rendered plans must not contain resolved secret values. Hostwright also redacts keychain reference labels because service/account names can reveal local context.

## Rejected Paths

- no plaintext secret persistence;
- no secrets in examples beyond reference-shaped placeholders;
- no provider credentials, cloud secret managers, ambient identity, or registry credential storage;
- no mounted secret files, multiline secret payloads, or binary secret blobs;
- no Compose/Kubernetes `secrets:` compatibility.
