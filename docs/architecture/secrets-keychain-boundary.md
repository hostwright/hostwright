# Secrets And Keychain Boundary

Status: Phase 05 provider boundary.

Hostwright supports typed manifest secret references:

```yaml
secretEnv:
  API_TOKEN: keychain://hostwright.api/api-token
  DEPLOY_TOKEN: env-file:///Users/example/.config/hostwright/secrets.env#DEPLOY_TOKEN
  LICENSE: local-file:///Users/example/.config/hostwright/license
  EXTERNAL_TOKEN: external://registered-provider/api-token
  PLUGIN_TOKEN: plugin://registered-provider/api-token
```

The manifest stores a typed reference, not a secret value. Plaintext sensitive keys under `env` fail validation, and the same key cannot appear in both `env` and `secretEnv`.

## Execution Boundary

Planning, status, state persistence, diagnostics, events, and errors see only redacted secret-reference metadata. Confirmed create actions resolve each reference for one exact project UUID, resource UUID, resource generation, service, and environment key immediately before calling `RuntimeAdapter.execute`. A missing grant, unavailable provider, stale result, cancellation, or identity mismatch fails before runtime mutation.

`MacOSKeychainSecretStore` is the production backend for managed local generic-password items. It queries an exact service/account pair, creates and updates only Hostwright-owned records, excludes synchronizable items, uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and supplies a `LAContext` with interaction disabled so a CLI process never presents authentication UI. Tests inject `InMemorySecretStore` for deterministic failure contracts and separately exercise the live backend against uniquely named real Keychain items.

The default workload resolver supports Keychain plus guarded environment and local files. File providers descriptor-walk absolute paths without following symlinks, require private current-user regular files with one link and no access-granting ACL, bound values to 64 KiB UTF-8 without null bytes, and verify file identity after reading. Environment files use a strict command-free `KEY=value` grammar and reject duplicate or malformed keys.

`external://` and `plugin://` references require an explicitly registered provider with a stable matching authority. Hostwright runs no shell command, plugin loader, network client, or ambient credential fallback for these references in Phase 05; absent registration fails closed. Provider results carry bounded version and refresh/expiry metadata. A result that is expired or already requires refresh is rejected.

## Live Keychain Gate

The live integration gate creates a unique non-synchronizable generic-password item with `SecItemAdd`, resolves it through `MacOSKeychainSecretStore`, deletes the exact service/account item with `SecItemDelete`, and verifies a second lookup returns `errSecItemNotFound`. A malformed-data case proves non-UTF-8 item data fails without exposing the service, account, or bytes. There is no conditional skip path: unavailable Keychain access, disallowed interaction, or failed cleanup fails the test.

Production code creates, updates, lists metadata for, and exactly deletes only Hostwright-owned Keychain items. Access groups, synchronizable items, biometric or prompt-gated access control, custom keychain selection, credential sync, and credential upload remain out of scope.

## Persistence Boundary

State rows, events, operations, diagnostics, and rendered plans must not contain resolved secret values. Hostwright redacts all provider references because service names, item names, and local paths can reveal context. The Apple CLI receives sensitive values through its inherited environment and only the variable name in argv.

## Rejected Paths

- no plaintext secret persistence;
- no secrets in examples beyond reference-shaped placeholders;
- no bundled cloud secret manager, provider credential store, ambient identity, or registry credential storage;
- no mounted secret files or binary secret blobs;
- no external or plugin provider execution without explicit registration and grants;
- no Compose/Kubernetes `secrets:` compatibility.
