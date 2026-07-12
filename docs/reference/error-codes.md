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
| `HW-STATE-001` | State store unavailable. | Implemented for invalid paths, migration failure, incompatible/future schema, corrupt database, locked database, and read/write failures |
| `HW-SECURITY-001` | Unsafe exposure. | Modelled |
| `HW-TEAM-001` | Team profile is malformed, unsupported, or violates required gates. | Implemented for strict JSON parsing and profile policy evaluation |
| `HW-TEAM-002` | Approval record is malformed, rejected, unsupported, or incomplete. | Implemented for profile-aware apply and confirmed cleanup |
| `HW-TEAM-003` | Approval scope or profile/manifest/plan binding does not match the current operation. | Implemented as confirmation mismatch before runtime mutation |
| `HW-BENCH-001` | Benchmark options or report contract are invalid. | Implemented before file or runtime access |
| `HW-BENCH-002` | Hardware benchmark evidence is blocked by a missing capability or unmeasured required dimension. | Implemented with exit code 69 and a written blocked report |
| `HW-BENCH-003` | Hardware benchmark command, version, identity, ownership, report, or cleanup evidence failed. | Implemented with exit code 72 and a written failed report when possible |

## Process Exit Codes

| Exit code | Category | Used for |
| ---: | --- | --- |
| `0` | Success | Completed command. |
| `64` | Usage | Invalid arguments, unsupported flags, missing required confirmation/state arguments, refused overwrite, or local non-manifest file I/O failure. |
| `65` | Validation | Missing/unreadable manifest, manifest/profile/approval validation failure, unsupported manifest/import feature, stack-file import rejection, or compatibility validation failure. |
| `66` | State unavailable | Explicit state database path failed validation, migration, schema compatibility, locking, corruption, or read/write. |
| `69` | Runtime unavailable or evidence blocked | Runtime access failed or a benchmark prerequisite/dimension remains blocked. |
| `70` | Confirmation mismatch | Confirmed plan hash, cleanup token, approval scope, or approval hash binding does not match the current operation. |
| `71` | Unsafe operation | Planner or apply safety policy blocked mutation. |
| `72` | Partial failure | Mixed cleanup outcome or failed benchmark command/identity/cleanup evidence. |

JSON mode uses the same process exit codes. Classified CLI, manifest, import, state, and runtime failures use a JSON error envelope on stderr. `doctor --output json` reports compatibility failures as a normal doctor report on stdout with `hasFailures: true` and exit code 65.
