# Operational risks

| Risk | Control and verification |
| --- | --- |
| Runtime behavior changes across versions. | Negotiate the provider version and capabilities; run conformance for the declared matrix. Reject incompatible responses before mutation. |
| Interrupted operations lose ownership or state. | Persist intent and fences before effects, verify results, and test interruption recovery and backup restoration. Preserve ambiguous resources for inspection. |
| Local paths or installed files are replaced. | Validate ownership, permissions, identity, and digests through descriptor-bound operations; test replacement and symlink refusal. |
| Credentials or private data enter diagnostics. | Redact before persistence, bound collected content, require support-bundle preview/confirmation, and test excluded fields and failure paths. |
| Artifact metadata describes different bytes. | Bind source, payloads, signatures, notices, and provenance to the exact staged inventory; verify downloads and installed artifacts independently. |
| Documentation overstates support. | Match command examples and compatibility claims to passing source and artifact evidence. Qualify the deployed quickstarts before GA. |

See [security architecture](architecture/security-model.md), [local recovery](reference/local-recovery.md), and the [release process](release/RELEASE_PROCESS.md) for implementation details and required checks.
