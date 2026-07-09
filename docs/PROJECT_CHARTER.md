# Hostwright Project Charter

Hostwright is a Mac-native desired-state control plane for Apple container workloads.

The first supported release is intentionally narrow: one local Apple silicon Mac, macOS 26+, Apple container workloads, and a conservative control-plane foundation. Phase 40 keeps current core on the single-host path; Kubernetes-class, CRI, cloud, multi-host, remote-placement, and accelerator-aware platform work require separate approval and proof.

## Product Boundary

Hostwright should:

- read and validate `hostwright.yaml`;
- store desired state locally;
- observe runtime state through a `RuntimeAdapter`;
- compute drift and planned actions before mutation;
- expose health, status, events, and logs interfaces;
- fail clearly when platform or runtime assumptions are not met.

Hostwright should not present itself as a cluster orchestrator, compatibility shim, cloud control plane, multi-host platform, accelerator scheduler, web dashboard, or production hosting platform.

## Engineering Boundary

Swift and Swift Package Manager are the default implementation path. Runtime operations are isolated behind adapter and process-execution boundaries. Destructive operations require dry-run and confirmation design before they exist.
