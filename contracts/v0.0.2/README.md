# v0.0.2 Golden Contracts

These files are executable compatibility fixtures for the contracts locked in Phase 01. Tests decode them with production types/parsers; changing a file or model requires a reviewed contract decision, migration/compatibility update, and refreshed consumer evidence.

- `versions.json`: product/release and Manifest, Control API, Runtime Provider API, Storage Provider API, Network Provider SPI, plugin ABI, and state schema versions.
- `manifest.yaml`: smallest accepted explicit Manifest v2 application.
- `control-plan-request.json`: smallest accepted Control API v2 plan request.
- `control-plan-response.json`: stable Control API v2 response envelope.
- `runtime-provider-metadata.json`: Runtime Provider API v2 capability metadata.
- `runtime-provider-capabilities.json`: canonical Runtime Provider API v2 capability-snapshot grammar.
- `plugin-declaration.json`: plugin ABI v1 reviewed-local declaration supported by the current narrow extension boundary.

## Phase 09 Gate 1 freeze

The following fixtures freeze Phase 09 contracts. Gates 2–5 implement the
identity, persistent unary Control API, tamper-evident audit, and RBAC portions.
The remaining fixtures are still inputs to their later qualification gates and
do not claim that streams, admission, profiles, provider runtimes, XPC, or the
plugin lifecycle are already implemented.

- `phase09-control-request-v2.1.json`: revision 2.1 persistent Control API request.
- `phase09-control-response-v2.1.json`: revision 2.1 response and reason-code envelope.
- `phase09-auth-challenge-v2.1.json`: server-first local authentication challenge.
- `phase09-auth-response-v2.1.json`: credential-bearing client authentication response.
- `phase09-stream-frame-v2.1.json`: revision 2.1 stream frame.
- `phase09-rbac-v2.1.json`: scoped RBAC rule vocabulary.
- `phase09-default-role-matrix.json`: frozen default-role permission matrix.
- `phase09-admission-v2.1.json`: admission decision fixture.
- `phase09-audit-v2.1.json`: canonical audit-record field fixture.
- `phase09-profile-v1.json`: Workload Profile v1 fixture.
- `phase09-plugin-v1.json`: signed, digest-addressed Plugin ABI v1 package manifest.
- `phase09-plugin-invocation-v1.json`: bounded deterministic provider invocation.
- `phase09-xpc-v1.json`: independently versioned XPC request.
- `phase09-migration-plan-v18-v21.json`: v17→v21 migration/backup/refusal/restore plan.
- `phase09-cli-parity-inventory.json`: complete CLI transport classification.

`control-plan-request.json` and `control-plan-response.json` remain the legacy
revision 2.0 compatibility fixtures. Revision 2.1 must preserve their decode
and response behavior rather than silently reinterpret them.

The full frozen boundary and implementation sequencing are documented in
[`phase09-control-plane-contracts.md`](../../docs/architecture/phase09-control-plane-contracts.md).
The associated threat model is
[`hostwright-phase09-threat-model.md`](../../docs/architecture/hostwright-phase09-threat-model.md).

Runtime Provider API v2 uses the stable provider IDs `apple-container-cli` and `apple-containerization`. Its metadata and capability-snapshot codecs are locked by production-decoded goldens. The Containerization boundary uses helper protocol v1 with bounded length-prefixed canonical JSON frames; protocol, replay, truncation, overflow, and version-refusal behavior is locked by executable contract tests rather than a placeholder wire fixture.
