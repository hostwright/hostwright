# Error Codes

Stable error codes are used for CLI and manifest diagnostics.

| Code | Meaning | Status |
| --- | --- | --- |
| `HW-CLI-001` | Invalid CLI usage. | Implemented |
| `HW-CLI-002` | Refused to overwrite an existing file. | Implemented for `init` |
| `HW-CLI-003` | Confirmation token or plan hash mismatch. | Implemented for confirmed apply plan mismatch and cleanup token mismatch |
| `HW-CLI-004` | Partial operation failure. | Implemented for cleanup partial failure |
| `HW-COMPAT-001` | Unsupported CPU architecture. | Implemented in compatibility/doctor model |
| `HW-COMPAT-002` | Unsupported macOS version. | Implemented in compatibility/doctor model |
| `HW-RUNTIME-001` | Runtime adapter unavailable. | Modelled |
| `HW-RUNTIME-002` | Runtime mutation not implemented. | Modelled |
| `HW-MANIFEST-001` | Manifest parsing failed. | Implemented |
| `HW-MANIFEST-002` | Manifest validation failed. | Implemented, including invalid version shape and unsafe env/volume values |
| `HW-MANIFEST-003` | Unsupported manifest/YAML feature. | Implemented, including unsupported fields and explicit older/newer manifest versions |
| `HW-MANIFEST-004` | Manifest file I/O failed. | Implemented |
| `HW-STATE-001` | State store unavailable. | Implemented for invalid paths, migration failure, incompatible/future schema, corrupt database, locked database, and read/write failures |
| `HW-SECURITY-001` | Unsafe exposure. | Modelled |

## Process Exit Codes

| Exit code | Category | Used for |
| ---: | --- | --- |
| `0` | Success | Completed command. |
| `64` | Usage | Invalid arguments, unsupported flags, missing required confirmation/state arguments, refused overwrite. |
| `65` | Validation | Manifest parse or validation failure, unsupported manifest feature, compatibility validation failure. |
| `66` | State unavailable | Explicit state database path failed validation, migration, schema compatibility, locking, corruption, or read/write. |
| `69` | Runtime unavailable | Runtime observation, logs, or mutation failed through `RuntimeAdapter`. |
| `70` | Confirmation mismatch | Confirmed plan hash or cleanup token does not match the current observed plan. |
| `71` | Unsafe operation | Planner or apply safety policy blocked mutation. |
| `72` | Partial failure | At least one requested operation succeeded and at least one failed. |

JSON mode uses the same process exit codes. Classified CLI, manifest, state, and runtime failures use a JSON error envelope on stderr. `doctor --output json` reports compatibility failures as a normal doctor report on stdout with `hasFailures: true` and exit code 65.
