# Doctor Checks

`hostwright doctor [--state-db <path>] [--json | --output text|json]` is the non-mutating readiness gate for the local Hostwright installation. It reports what is usable now, what is degraded, what blocks safe work, what the host cannot support, and what depends on software or services outside Hostwright.

Doctor schema version 2 uses five stable readiness values:

| State | Meaning | Default exit behavior |
| --- | --- | --- |
| `ready` | The inspected boundary passed. | `0` |
| `degraded` | Work can continue, but a missing project input, development trust state, pressure condition, or unmeasured diagnostic needs attention. | `0` |
| `externally-constrained` | Hostwright is intact, but Apple container or another required external tool/service is unavailable. | `69` |
| `blocked` | Continuing would violate a local safety, integrity, permission, or trust requirement. | `65`, or `66` for state-integrity failure |
| `unsupported` | The hardware or operating-system contract is not supported. | `65` |

Overall readiness uses the strictest observed state: `unsupported`, `blocked`, `externally-constrained`, `degraded`, then `ready`. A blocked path-policy result takes exit 65. A state database that passes path policy but fails immutable integrity inspection takes exit 66. The JSON report is still written to stdout for every classified readiness result.

## Implemented Checks

| Check | Evidence source | Ready condition | Non-ready behavior |
| --- | --- | --- | --- |
| `operatingSystem` | `ProcessInfo` | The OS description was read. | The value remains diagnostic; compatibility is decided separately. |
| `appleSilicon` | Public process architecture | The host is Apple silicon. | Unsupported hardware is `unsupported`. |
| `macOSVersion` | Public OS version | The configured minimum macOS major is met. | An older major is `unsupported`. |
| `appleContainerCLI` | Secure executable resolution | A `container` executable is discoverable. | Missing CLI is `externally-constrained`. |
| `appleContainerService` | `RuntimeAdapter.runtimeReadiness()` | Bounded version and `container system status --format json` probes report a running service. | Only normalized semantic versions and a bounded printable build token enter the report; duplicate JSON fields fail closed. Apple's documented status-1 JSON for not-running and unregistered services is parsed as a typed external constraint; unavailable, malformed, timed-out, or overflowing probes are also externally constrained, while permission denial is blocked. |
| `manifestPresence` | Current working directory | `hostwright.yaml` exists. | Absence is degraded because explicit manifest paths remain valid. |
| `statePathPolicy` | Secure local-path resolver and file policy | The selected existing or prospective path passes origin, ownership, mode, ACL, symlink, link-count, and identity checks. | Migration is degraded. Conflict or policy failure is blocked. |
| `stateIntegrity` | Immutable SQLite inspection | An existing checkpointed database passes application identity, SQLite, foreign-key, migration, schema, authoritative-record, and projection checks. | No database is degraded. Repairable projections are degraded. Corruption, foreign ownership, active/nonempty WAL ambiguity, or failed inspection is blocked. |
| `statePermissions` | The same descriptor-based path policy | Ownership, `0700` directory, `0600` sensitive-file, ACL, special-bit, and file-identity requirements pass. | Unverified facts are degraded; violations are blocked. |
| `localNetwork` | Public `getifaddrs` interface data | Loopback and at least one active non-loopback interface are present. | Missing loopback is blocked. Offline external networking is degraded. |
| `signingTrust` | Bounded `/usr/bin/codesign` and `/usr/sbin/spctl` assessment | A release build has a valid Developer ID Application signature accepted by Gatekeeper. | Development ad-hoc/unsigned trust is degraded. Invalid or untrusted release artifacts are blocked. |
| `resourcePressure` | Public Mach VM statistics and `ProcessInfo.thermalState` | Reclaimable memory is at least 20 percent and thermal state is nominal. | Fair/serious thermal state, unknown facts, or memory below 20 percent is degraded. Critical thermal state or memory below 5 percent is blocked. |
| `requiredTools` | Secure executable/file lookup | Required runtime tools are available. Optional developer-tool availability remains machine-readable context. | A missing runtime requirement is externally constrained. A release install does not require the optional Swift toolchain. |
| `telemetryPolicy` | Product contract | Diagnostics remain local with no upload. | There is no silent telemetry fallback. |
| `resourceIntelligence` | Existing local resource-report model | The extended local snapshot is available without thermal warning. | Missing or thermally constrained extended evidence is degraded and never becomes a capacity claim. |

Every non-ready check includes a remediation string. JSON check objects also include stable identifiers and string-valued details suitable for local automation. Diagnostics and details pass through the runtime redaction policy, and runtime error text is flattened and limited to 512 characters.

## Non-Mutation Contract

Doctor may execute only these external read boundaries:

- the Apple CLI version and structured system-status commands through `RuntimeAdapter`;
- `/usr/bin/codesign --verify` and `--display` for the running executable;
- `/usr/sbin/spctl --assess` for Gatekeeper status;
- public host interface, memory, thermal, OS, architecture, and executable-availability reads.

It does not list or inspect containers, images, networks, volumes, logs, registries, or workload processes. It does not start Apple services, request Local Network authorization, create proof workloads, pull images, write state, migrate state, checkpoint an active external writer, repair data, create lock files, upload diagnostics, or alter signing trust.

Existing state inspection opens a sidecar-free checkpointed database with SQLite `mode=ro&immutable=1`. Doctor uses an existing Hostwright shared fence when one exists, but never creates the fence. It records and revalidates database identity, content fingerprint, and checkpointed sidecar state around the inspection. A rollback journal, nonempty WAL, held exclusive fence, or content change makes the inspection temporarily unavailable instead of being mislabeled as proven corruption. Wait for the active operation, or complete an explicit Hostwright checkpoint/recovery workflow when a maintenance journal exists, before retrying.

The Local Network check intentionally does not trigger the macOS Local Network consent prompt. `authorizationWasProbed` remains `false`; interface availability is evidence of host connectivity, not proof that a future LAN listener has user authorization.

## Machine-Readable Flow

```text
resolve selected state path without creation
  -> validate prospective/existing path policy
  -> inspect checkpointed existing state immutably, if present
  -> query RuntimeAdapter readiness with bounded output/time
  -> read public host/network/pressure facts
  -> verify executable signature and Gatekeeper assessment
  -> classify each check
  -> select strictest overall readiness
  -> emit text or schema-v2 JSON and a stable exit code
```

Representative JSON fields:

```json
{
  "kind": "doctor",
  "schemaVersion": 2,
  "readiness": "degraded",
  "hasFailures": false,
  "hasExternalConstraints": false,
  "checks": [
    {
      "identifier": "stateIntegrity",
      "status": "ready",
      "message": "The existing state database passed immutable integrity inspection.",
      "details": {
        "stateSchemaVersion": "7"
      }
    }
  ]
}
```

Use `hostwright paths --json` for the complete selected layout and `hostwright state integrity --json` for the full state-maintenance report. Those commands have separate contracts; doctor remains a readiness summary.
