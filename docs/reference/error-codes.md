# Error Codes

Stable error codes are used for CLI and manifest diagnostics.

| Code | Meaning | Status |
| --- | --- | --- |
| `HW-CLI-001` | Invalid CLI usage. | Implemented |
| `HW-CLI-002` | Refused to overwrite an existing file. | Implemented for `init`, diagnostics bundles, and benchmark reports |
| `HW-CLI-003` | Confirmation token or plan hash mismatch. | Implemented for confirmed apply plan mismatch and cleanup token mismatch |
| `HW-CLI-004` | Partial operation failure. | Implemented for cleanup partial failure |
| `HW-CLI-005` | Local file I/O failed. | Implemented for `init` writes, stack-file import reads, and diagnostics input/output paths |
| `HW-COMPAT-001` | Unsupported CPU architecture. | Implemented in compatibility/doctor model |
| `HW-COMPAT-002` | Unsupported macOS version. | Implemented in compatibility/doctor model |
| `HW-RUNTIME-001` | Runtime adapter unavailable. | Modelled |
| `HW-RUNTIME-002` | Runtime mutation not implemented. | Modelled |
| `HW-MANIFEST-001` | Manifest parsing failed. | Implemented |
| `HW-MANIFEST-002` | Manifest validation failed. | Implemented, including invalid version shape, unsafe env/volume values, and converted import output that fails Hostwright validation |
| `HW-MANIFEST-003` | Unsupported manifest/YAML feature. | Implemented, including unsupported fields, explicit older/newer manifest versions, and unsupported stack-file import fields |
| `HW-MANIFEST-004` | Manifest file I/O failed. | Implemented consistently for validate, plan, status, apply, logs, and cleanup manifest reads |
| `HW-STATE-001` | State store unavailable. | Implemented for resolution/override errors, unsafe ownership/mode/ACL/symlink/hard-link/parent paths, legacy migration conflicts or journal failures, incompatible/future schema, corrupt/locked databases, and read/write failures |
| `HW-SECURITY-001` | Unsafe exposure. | Modelled |
| `HW-TEAM-001` | Team profile is malformed, unsupported, or violates required gates. | Implemented for strict JSON parsing and profile policy evaluation |
| `HW-TEAM-002` | Approval record is malformed, rejected, unsupported, or incomplete. | Implemented for profile-aware apply and confirmed cleanup |
| `HW-TEAM-003` | Approval scope or profile/manifest/plan binding does not match the current operation. | Implemented as confirmation mismatch before runtime mutation |
| `HW-BENCH-001` | Benchmark options or report contract are invalid. | Implemented before file or runtime access |
| `HW-BENCH-002` | Hardware benchmark evidence is blocked by a missing capability or unmeasured required dimension. | Implemented with exit code 69 and a written blocked report |
| `HW-BENCH-003` | Hardware benchmark command, version, identity, ownership, report, or cleanup evidence failed. | Implemented with exit code 72 and a written failed report when possible |
| `HW-DIST-001` | Distribution arguments, source binding, artifact verification, command, ownership, installed lifecycle, or recovery failed. | Implemented by `hostwright-dist`; exit categories 64, 65, 69, 71, or 72 identify the failure class, including downgrade/version refusal, ownership refusal, and durable recovery failure |
| `HW-DIST-002` | Unsigned artifact assembly or temp-prefix lifecycle succeeded, but required distribution trust stages remain blocked. | Implemented with exit code 69 and blocked `distribution-artifact` evidence |
| `HW-SECRET-001` | Secret reference, value, or managed metadata is invalid. | Implemented before unsafe mutation |
| `HW-SECRET-002` | The selected secret backend is unavailable or cannot interact noninteractively. | Implemented with exit code 69 |
| `HW-SECRET-003` | The exact managed secret item does not exist. | Implemented with exit code 66 |
| `HW-SECRET-004` | A duplicate, unmanaged item, replacement race, or active same-secret mutation conflicts. | Implemented with exit code 72 |
| `HW-SECRET-005` | Keychain denied the requested operation. | Implemented with exit code 71 |
| `HW-SECRET-006` | The secret operation was cancelled before a safe terminal result. | Implemented with exit code 72 |
| `HW-SECRET-007` | The Keychain effect or durable checkpoint is partial or ambiguous. | Implemented with exit code 72 and recovery guidance |
| `HW-REGISTRY-001` | Registry endpoint, scope, challenge, token, credential configuration, or response is invalid. | Implemented with exit code 65 |
| `HW-REGISTRY-002` | No exact registry credential or required credential helper is available. | Implemented with exit code 69 |
| `HW-REGISTRY-003` | The registry or Keychain denied authentication. | Implemented with exit code 71 |
| `HW-REGISTRY-004` | Registry TLS transport, token service, or credential helper is unavailable. | Implemented with exit code 69 |
| `HW-REGISTRY-005` | A challenge or token denied or attempted to expand the requested registry scope. | Implemented with exit code 71 |
| `HW-REGISTRY-006` | Registry authentication or credential lookup was cancelled. | Implemented with exit code 72 |
| `HW-REGISTRY-007` | Registry credential mutation or its durable checkpoint has a partial or ambiguous effect. | Implemented with exit code 72 |
| `HW-IMAGE-001` | Image request, reference, path, platform, progress, or structured provider result is invalid. | Implemented before unsafe mutation |
| `HW-IMAGE-002` | The selected provider or image operation is unavailable. | Implemented with exit code 69 |
| `HW-IMAGE-003` | A target collision, ownership mismatch, digest drift, live reference, or active image intent conflicts. | Implemented with exit code 72 |
| `HW-IMAGE-004` | Image ownership, filesystem identity, or destructive-operation policy denied the operation. | Implemented with exit code 71 |
| `HW-IMAGE-005` | Image execution was cancelled and exact compensation was attempted. | Implemented with exit code 72 |
| `HW-IMAGE-006` | An image provider or durable checkpoint has a partial or ambiguous effect requiring recovery. | Implemented with exit code 72 |

## Process Exit Codes

| Exit code | Category | Used for |
| ---: | --- | --- |
| `0` | Success | Completed command. |
| `64` | Usage | Invalid arguments, unsupported flags, missing required confirmation arguments, refused overwrite, local non-manifest file I/O failure, or invalid distribution path/command shape. |
| `65` | Validation | Missing/unreadable manifest, manifest/profile/approval validation failure, unsupported manifest/import feature, stack-file import rejection, compatibility validation failure, invalid distribution source/artifact evidence, downgrade refusal, or installed/candidate version conflict. |
| `66` | State unavailable | Selected state database resolution, path policy, legacy migration, schema compatibility, locking, corruption, or read/write failed. |
| `69` | Runtime/tool unavailable or evidence blocked | Runtime or required local/distribution tool execution failed, a benchmark dimension remains blocked, or unsigned distribution work completed without required trust stages. |
| `70` | Confirmation mismatch | Confirmed plan hash, cleanup token, approval scope, or approval hash binding does not match the current operation. |
| `71` | Unsafe operation | Planner/apply safety policy blocked mutation or distribution ownership validation refused replacement, repair, or removal. |
| `72` | Partial failure | Mixed cleanup outcome, failed benchmark command/identity/cleanup evidence, or installed distribution lifecycle/recovery could not complete safely. |

JSON mode uses the same process exit codes. Classified CLI, manifest, import, state, and runtime failures use a JSON error envelope on stderr. Installed-lifecycle `hostwright-dist` commands require `--output json` and use this schema-1 stderr envelope:

```json
{"schemaVersion":1,"kind":"distributionToolError","code":"HW-DIST-001","message":"...","exitCode":72}
```

The `message` supplies the exact refusal or recovery instruction; automation should branch on `code` and `exitCode`, then inspect `hostwright-dist status` after interruption. `doctor --output json` reports readiness as a normal doctor document on stdout: unsupported/blocked policy exits 65, failed existing-state integrity exits 66, and an external runtime constraint exits 69.
