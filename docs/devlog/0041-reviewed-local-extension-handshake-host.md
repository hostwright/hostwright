# Phase 41: Reviewed-Local Executable Extension Handshake Host

Issue #98 implements the first executable extension boundary after the Phase 33 declaration policy.

## Implemented

- strict flat declaration JSON for one capability, reviewed-local trust, API/protocol version 1, purpose, boundaries, and exact executable SHA-256;
- existing `ExtensionPolicyEvaluator` enforcement before process launch;
- caller ownership, regular-file, non-symlink, safe-write-mode, owner-execute, size, and digest checks;
- descriptor-to-private-stage copying with mode `0500`, hashing during copy, and exact file/directory cleanup;
- one fixed JSON handshake argument and operation with a minimal environment, `/` working directory, timeout, concurrent bounded stdout/stderr drains, empty successful stderr, and strict response binding;
- text/JSON `hostwright extension check` output and stable `HW-EXT-001`, `HW-EXT-002`, and `HW-EXT-003` errors.

## Evidence

- Seven parser/policy unit-contract tests cover exact input, unknown/missing/duplicate fields, version/trust blockers, mutable and mismatched capability blockers, identity/purpose/digest/boundary validation, and document size.
- Five local-integration XCTest cases compile a real Swift fixture executable and exercise successful stdin/stdout protocol exchange, digest mismatch, policy blocking, symlink and permission rejection, timeout, output overflow, nonzero exit, malformed/duplicate/extra output, binding mismatch, unexpected stderr, source-file preservation, and empty staging after every result.
- `scripts/integration.sh` compiles the same protocol fixture separately and runs the built `hostwright` binary in text and JSON modes. A secret-like parent environment value is present for the CLI process but absent from the extension process; process failure returns a redacted JSON error and exit 72.

These are `unit-contract` and `local-integration` results. They do not prove third-party ecosystem compatibility, capability behavior, operating-system sandboxing, restriction of ambient user privileges, descendant-process containment, signing, notarization, or distribution trust. The reviewed executable can still use the invoking account's ordinary file, process, and network access; `reviewedLocal` is a code-review trust decision, not confinement.

## Boundaries

No generic plugin loader, discovery, installation, persistence, registry, binary distribution, capability payload or invocation, untrusted execution, RuntimeAdapter access, Apple container command, SQLite/state access, secret resolution, network/tunnel/provider behavior, accelerator access, remote control, dependency, release tag, GitHub Release, website work, or GUI code was added.
