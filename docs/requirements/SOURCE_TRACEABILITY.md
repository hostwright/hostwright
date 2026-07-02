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
| The product is a Mac-native single-host desired-state control plane above Apple container. | Document 1 | HW-RECON-001, HW-RUNTIME-001, HW-COMPAT-001, HW-COMPAT-002 | Partially implemented | Current repo has CLI/manifest/planning scaffolds but no runtime observation or mutation. |
| The public identity is Hostwright, with CLI `hostwright`, daemon `hostwrightd`, and manifest `hostwright.yaml`. | Naming archive | HW-NAME-001, HW-NAME-002, HW-NAME-003, HW-NAME-004 | Implemented | Old name remains only as source-material history or naming decision context. |
| Swift and Swift Package Manager are the implementation direction. | Document 1; Final document | HW-CLI-001, HW-RUNTIME-001, HW-STATE-001 | Implemented | SwiftPM exists and builds. Runtime/state are still mostly scaffolds. |
| Runtime behavior must be isolated behind RuntimeAdapter. | Document 1; Final document | HW-RUNTIME-001, HW-RUNTIME-002, HW-RUNTIME-003, HW-RUNTIME-004 | Partially implemented | Protocol exists. Process execution and adapter contract hardening are Phase 4. |
| No reconciler or CLI logic may call container CLI directly. | Document 1; Final document | HW-RUNTIME-002 | Partially implemented | Phase 2 only does executable lookup and `swift --version`; Phase 4 must enforce this with tests. |
| First supported release must validate manifests. | Document 1 | HW-MANIFEST-001, HW-MANIFEST-002, HW-VALID-001, HW-VALID-002, HW-VALID-003 | Partially implemented | Implemented for a restricted Hostwright manifest subset. |
| Full YAML parsing may use a YAML parser after dependency approval. | Final document | HW-MANIFEST-004 | Planned | Current parser is intentionally restricted and must not become accidental long-term YAML infrastructure. |
| Desired state must be stored durably in SQLite. | Document 1; Final document | HW-STATE-001, HW-STATE-002 | Planned | Current state module is an interface boundary only. |
| Events and operation records must be persisted and survive restart. | Document 1; Document 2; Final document | HW-STATE-003, HW-OBS-001 | Planned | Required before runtime mutation. |
| Reconciliation must load desired state, observe runtime, diff, plan, validate safety gates, persist intent, apply, record events, and observe again. | Document 1 | HW-RECON-001, HW-RECON-002, HW-RECON-003, HW-RECON-004, HW-RECON-005 | Partially implemented | Phase 7 implements deterministic non-mutating drift planning; apply, persistence of apply intent, mutation, and observe-after-apply remain future. |
| Apply must support dry-run action plans before mutation. | Document 2 | HW-SAFE-001, HW-CLI-008, HW-RECON-004 | Planned | Phase 2 `plan` exists but no real runtime apply exists. |
| Destructive operations require ownership checks, confirmation, and audit events. | Document 2 | HW-SAFE-002, HW-SAFE-003, HW-STATE-005 | Planned | Cleanup is not implemented. |
| Named volumes must not be deleted by default. | Document 2 | HW-SAFE-003 | Planned | No cleanup or volume mutation exists. |
| Secrets must not leak into manifests, logs, events, status, crash reports, fixtures, or docs. | Document 2 | HW-SAFE-004, HW-STATE-004, HW-OBS-003 | Planned | Current repo avoids runtime secret handling. Redaction tests are not yet present. |
| Privileged helpers are not allowed unless proven necessary by threat model. | Document 2 | HW-SAFE-005 | Rejected | Rejected for first supported release. |
| Apple silicon and macOS 26+ are first-release constraints. | Document 1; Document 2; Final document | HW-COMPAT-001, HW-COMPAT-002, HW-COMPAT-003 | Implemented | Code and docs model these compatibility gates. |
| GPU/ANE/Metal/Core ML/MLX support inside containers must not be claimed without proof. | Document 2 | HW-COMPAT-004 | Rejected | Not in first supported release. |
| Networking must be declared state with policy and diagnostics, not incidental shell output. | Document 3 | HW-NET-001, HW-NET-002, HW-NET-003 | Planned | Current networking module is a boundary scaffold only. |
| LAN, tunnel, public, and cloud exposure require separate research and policy gates. | Document 3 | HW-NET-004, HW-SAFE-006 | Deferred | Explicitly outside current release implementation. |
| No CRI, Kubernetes API server, Kubernetes scheduler, Docker API shim, or full Compose parity in first release. | Document 1; Final document | HW-COMPAT-005 | Rejected | ADRs and limitations document this. |
| Every supported command must have docs, examples, and tests. | Document 1 | HW-DOCS-001, HW-DOCS-002 | Partially implemented | Phase 2 commands are documented. Future commands must update docs with implementation. |
| Public docs must state unsupported behavior clearly. | Document 1; Final document | HW-DOCS-002, HW-DOCS-003 | Partially implemented | Phase 3 audits and corrects overclaims. |
| Public release requires build/test/docs/security/release gates. | Document 1; Final document; Document 2 | HW-REL-001, HW-REL-002, HW-REL-003, HW-REL-004 | Planned | Release hardening is Phase 10. |

## Deferred Or Rejected Source Claims

| Claim family | Source document | Requirement IDs | Status | Reason |
| --- | --- | --- | --- | --- |
| CRI / Kubernetes compatibility | Document 1; Final document | HW-COMPAT-005 | Rejected | The first release is local single-host control, not a Kubernetes node or compatibility shim. |
| Full Docker Compose parity | Document 1; Final document | HW-COMPAT-005 | Rejected | Hostwright borrows readable local stack ideas without becoming a Compose clone. |
| Docker API shim | Document 1; Final document | HW-COMPAT-005 | Rejected | The source docs reject this as core product direction. |
| Tunnels, DNS service, cloud connectors | Document 3 | HW-NET-004, HW-SAFE-006 | Deferred | Requires separate research, policy, and security gates. |
| GPU/ANE scheduling or Metal/Core ML/MLX container support | Document 2 | HW-COMPAT-004 | Rejected | No support claim is allowed without proof; not part of first release. |
| Privileged helper | Document 2 | HW-SAFE-005 | Rejected | User-space first unless a later threat model proves necessity. |
