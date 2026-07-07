# Source Traceability

This file maps the preserved source-material claims to Hostwright requirement IDs. It does not add new product claims.

## Source Documents

- Document 1: `Orchard_Agent_Engineering_Manual (1).docx`
- Document 2: `Orchard_Document_2_Security_and_Apple_Silicon_Acceleration.pdf`
- Document 3: `Orchard_Document_3_Network_Tunnels_Protocols_Cloud_Security.pdf`
- Final document: `Orchard_Final_Production_Arsenal.pdf`
- Naming archive: `Hostwright_Naming_Convention_Folder.zip`

## Traceability Table

| Source claim | Source document | Requirement IDs | Status | Notes |
| --- | --- | --- | --- | --- |
| The product is a Mac-native single-host desired-state control plane above Apple container. | Document 1 | HW-RECON-001, HW-RUNTIME-001, HW-COMPAT-001, HW-COMPAT-002, HW-DAEMON-001 | Partially implemented | Current repo has CLI, manifest, planning, SQLite state, Apple observation, narrow apply, bounded logs, events, foreground daemon observation/planning, and ownership-gated cleanup. Full lifecycle management is not implemented. |
| The public identity is Hostwright, with CLI `hostwright`, daemon `hostwrightd`, and manifest `hostwright.yaml`. | Naming archive | HW-NAME-001, HW-NAME-002, HW-NAME-003, HW-NAME-004 | Implemented | Old name remains only as source-material history or naming decision context; `hostwrightd` now supports foreground dev mode only. |
| Swift and Swift Package Manager are the implementation direction. | Document 1; Final document | HW-CLI-001, HW-RUNTIME-001, HW-STATE-001 | Implemented | SwiftPM exists and builds. Runtime/state are still mostly scaffolds. |
| Runtime behavior must be isolated behind RuntimeAdapter. | Document 1; Final document | HW-RUNTIME-001, HW-RUNTIME-002, HW-RUNTIME-003, HW-RUNTIME-004 | Implemented for current runtime behavior | Observation, logs, create, managed start, and cleanup delete go through `RuntimeAdapter`; broader lifecycle actions still require new gates. |
| No reconciler or CLI logic may call container CLI directly. | Document 1; Final document | HW-RUNTIME-002 | Implemented for runtime behavior | Apple container command strings and execution remain isolated in `HostwrightRuntime`; doctor/toolchain checks remain non-runtime diagnostics. |
| First supported release must validate manifests. | Document 1 | HW-MANIFEST-001, HW-MANIFEST-002, HW-VALID-001, HW-VALID-002, HW-VALID-003 | Implemented for restricted subset | Phase 13 adds manifest version policy, contextual unsupported-field errors, unsafe env-key and unsafe mount-source validation, and schema/example alignment tests. |
| Full YAML parsing may use a YAML parser after dependency approval. | Final document | HW-MANIFEST-004 | Deferred | Current parser remains intentionally restricted; Phase 13 does not add a YAML dependency or general YAML support. |
| Desired state must be stored durably in SQLite. | Document 1; Final document | HW-STATE-001, HW-STATE-002, HW-STATE-006, HW-STATE-007 | Implemented | Phase 6 added explicit-path SQLite persistence with migrations and repository APIs. Phase 14 adds migration checksums, future/corrupt/locked failure handling, explicit read-vs-migrate boundaries, and backup/restore/export policy docs. |
| Events and operation records must be persisted and survive restart. | Document 1; Document 2; Final document | HW-STATE-003, HW-OBS-001 | Implemented for local ledger records | Phase 6 added event and operation ledgers; later phases record apply, status, logs, and cleanup events. |
| Reconciliation must load desired state, observe runtime, diff, plan, validate safety gates, persist intent, apply, record events, and observe again. | Document 1 | HW-RECON-001, HW-RECON-002, HW-RECON-003, HW-RECON-004, HW-RECON-005, HW-DAEMON-002, HW-DAEMON-004, HW-DAEMON-005 | Partially implemented | Planning, create, managed start, status observation, cleanup events, foreground daemon observe/health/plan/record behavior, and restart-state blocking exist. Observe-after-apply, unattended daemon mutation, and general lifecycle management remain future. |
| Apply must support dry-run action plans before mutation. | Document 2 | HW-SAFE-001, HW-CLI-008, HW-RECON-004 | Partially implemented | Apply requires a recomputed plan hash through `--confirm-plan` before a create or managed-start action can execute. |
| Destructive operations require ownership checks, confirmation, and audit events. | Document 2 | HW-SAFE-002, HW-SAFE-003, HW-STATE-005 | Implemented for exact container cleanup only | Cleanup requires dry-run, ownership, live observation, non-running lifecycle, exact resource ID, token confirmation, and persisted events. |
| Named volumes must not be deleted by default. | Document 2 | HW-SAFE-003 | Implemented by omission | No volume deletion command path exists. Cleanup deletes only exact containers. |
| Secrets must not leak into manifests, logs, events, status, crash reports, fixtures, or docs. | Document 2 | HW-SAFE-004, HW-STATE-004, HW-OBS-003, HW-HEALTH-002, HW-HEALTH-004 | Partially implemented | Runtime, state, planning, logs, status/events, apply, and health result tests cover fake secret redaction; redaction remains heuristic. |
| Health checks and restart policies should support local recovery decisions without uncontrolled restart loops. | Document 1; Document 2 | HW-HEALTH-001, HW-HEALTH-002, HW-HEALTH-003, HW-HEALTH-004, HW-HEALTH-005, HW-DAEMON-005 | Partially implemented | Phase 16 adds in-process loopback health probes, health result persistence, restart policy state, backoff, manual-disable, preexisting operator hold blocking, and crash-loop blocking. It does not add daemon-enforced restart mutation or a broad restart command. |
| Privileged helpers are not allowed unless proven necessary by threat model. | Document 2 | HW-SAFE-005 | Rejected | Rejected for first supported release. |
| Apple silicon and macOS 26+ are first-release constraints. | Document 1; Document 2; Final document | HW-COMPAT-001, HW-COMPAT-002, HW-COMPAT-003 | Implemented | Code and docs model these compatibility gates. |
| GPU/ANE/Metal/Core ML/MLX support inside containers must not be claimed without proof. | Document 2 | HW-COMPAT-004 | Rejected | Not in first supported release. |
| Networking must be declared state with policy and diagnostics, not incidental shell output. | Document 3 | HW-NET-001, HW-NET-002, HW-NET-003 | Partially implemented | Phase 7 added port planning policy; Phase 8B create supports only conservative published ports and rejects broad bind addresses and privileged host ports. |
| LAN, tunnel, public, and cloud exposure require separate research and policy gates. | Document 3 | HW-NET-004, HW-SAFE-006 | Deferred | Explicitly outside current release implementation. |
| No CRI, Kubernetes API server, Kubernetes scheduler, Docker API shim, or full Compose parity in first release. | Document 1; Final document | HW-COMPAT-005 | Rejected | ADRs and limitations document this. |
| Every supported command must have docs, examples, and tests. | Document 1 | HW-DOCS-001, HW-DOCS-002 | Partially implemented | Phase 2 commands are documented. Future commands must update docs with implementation. |
| Public docs must state unsupported behavior clearly. | Document 1; Final document | HW-DOCS-002, HW-DOCS-003 | Partially implemented | Phase 3 audits and corrects overclaims. |
| Public release requires build/test/docs/security/release gates. | Document 1; Final document; Document 2 | HW-REL-001, HW-REL-002, HW-REL-003, HW-REL-004 | Implemented for `v0.1.0-alpha.1` prep | Phase 10 prepares a source-only alpha release candidate with release docs, compatibility matrix, safety notes, limitations, and verification gates. |

## Deferred Or Rejected Source Claims

| Claim family | Source document | Requirement IDs | Status | Reason |
| --- | --- | --- | --- | --- |
| CRI / Kubernetes compatibility | Document 1; Final document | HW-COMPAT-005 | Rejected | The first release is local single-host control, not a Kubernetes node or compatibility shim. |
| Full Docker Compose parity | Document 1; Final document | HW-COMPAT-005 | Rejected | Hostwright borrows readable local stack ideas without becoming a Compose clone. |
| Docker API shim | Document 1; Final document | HW-COMPAT-005 | Rejected | The source docs reject this as core product direction. |
| Tunnels, DNS service, cloud connectors | Document 3 | HW-NET-004, HW-SAFE-006 | Deferred | Requires separate research, policy, and security gates. |
| GPU/ANE scheduling or Metal/Core ML/MLX container support | Document 2 | HW-COMPAT-004 | Rejected | No support claim is allowed without proof; not part of first release. |
| Privileged helper | Document 2 | HW-SAFE-005 | Rejected | User-space first unless a later threat model proves necessity. |
