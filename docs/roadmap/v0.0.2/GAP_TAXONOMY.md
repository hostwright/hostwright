# v0.0.2 Capability, Gap, and Evidence Taxonomy

This taxonomy prevents words such as “done,” “supported,” “research,” “blocked,” or “non-goal” from concealing implementation state.

## Build Capability States

`hostwright capabilities --json` uses exactly four states:

| State | Meaning | Allowed public wording | Closure effect |
| --- | --- | --- | --- |
| `stable` | The exact declared behavior is implemented and has its required evidence for this development contract. | “Implemented for the declared scope.” | Can contribute to an issue gate; release support still requires clean release evidence. |
| `experimental` | Runnable behavior exists, but scope, compatibility, recovery, security, or qualification is incomplete. | “Experimental/partial,” followed by exact limitation and owner. | Cannot close the broader implementation issue by itself. |
| `unavailable` | The user workflow is not implemented. Models, scaffolds, docs, mocks, and fixtures do not change this. | “Not implemented; planned in Phase NN / issue #NN.” | Fails any gate requiring the capability. |
| `blocked` | The ideal mechanism depends on unavailable public API or external authority. | “Blocked mechanism; implemented fallback is …” | Fails unless the issue explicitly requires the fallback rather than the external outcome. |

There is no capability state for “documented,” “researched,” “mostly,” “should work,” “mocked,” “fixture-backed,” “skipped,” or “non-goal.” Those are evidence/context attributes, never support states.

## Gap Dispositions

Every gap has one disposition:

1. **Implement:** a child issue owns runnable user behavior and evidence.
2. **Implement fallback:** an external constraint is named, but Hostwright owns a safe usable path (vendor tap, host-native accelerators, read-only quorum loss).
3. **Permanent mechanism exclusion:** only private APIs, unsupported platform emulation, unsafe quorum writes, silent telemetry, unauthenticated exposure, and unmanaged destructive GC. The user outcome is still implemented where a safe mechanism exists.

A gap cannot be moved to a later release or removed from `v0.0.2` merely by changing documentation. Change requires the master roadmap, issue manifest, limitation register, capability catalog, contracts/compatibility, and approval record to agree.

## Implementation Completion

A feature is implemented only when:

- the normal user workflow is runnable through the public surface;
- every accepted field/operation has observable behavior;
- boundary and invalid input fail explicitly;
- failure, cancellation, retry, recovery, migration, and rollback behavior is implemented where applicable;
- exact ownership and cleanup are verified;
- security and compatibility scope are recorded;
- required evidence passes from the exact clean commit;
- docs/examples/website match that scope.

Research, design, schema-only work, scaffolding, a protocol type, a mock provider, a fixture, a disabled code path, or a blocked live run can be valuable progress but remains incomplete.

## Evidence Classes

| Class | Required when |
| --- | --- |
| `unit-contract` | Deterministic logic, contracts, parsing, policy, state transitions, redaction. |
| `local-integration` | Real filesystem, subprocess, SQLite, Keychain, socket, or loopback boundary. |
| `live-runtime` | Real Apple runtime resources are observed or mutated. |
| `hardware-benchmark` | Performance, density, energy, thermal, sleep/wake, or accelerator behavior is claimed. |
| `distribution-artifact` | Build/sign/notarize/install/upgrade/rollback/uninstall or package-channel behavior is claimed. |
| `migration-upgrade` | Contract/state/data/artifact/cluster versions change. |
| `security-assessment` | A trust boundary, identity, secret, parser, public exposure, plugin, supply-chain, or tenant surface changes. |
| `resilience-chaos` | A daemon, saga, rollout, network/storage state, failover, or long-running recovery promise changes. |
| `multi-host` | More than one physical Mac participates in authoritative state or mutation. |
| `interop-conformance` | An external protocol/client/ecosystem compatibility claim is made. |
| `ux-accessibility` | GUI/menu-bar/MDM/team/cloud user workflows or accessibility are claimed. |

Evidence reports can be `passed`, `failed`, or `blocked`. There is no skipped-success status. A dirty report supports diagnosis, never release closure. Exact cleanup is mandatory for live runtime, hardware, resilience, multi-host, and interoperability evidence.

## Accountability Chain

```text
capability identifier
  -> limitation-register row
  -> phase epic
  -> stable child marker and GitHub issue
  -> required evidence classes
  -> final clean evidence comment
  -> exact compatibility/documentation claim
```

The machine-readable sources are `Sources/HostwrightCore/CapabilityCatalog.swift` and `docs/roadmap/v0.0.2/issues.json`. `scripts/roadmap-governance.py` validates the issue side; contract and CLI tests validate capability determinism and phase coverage.
