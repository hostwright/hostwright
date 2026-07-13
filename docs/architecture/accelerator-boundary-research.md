# Accelerator Boundary Research

> **Historical research, promoted to implementation:** Phase 10 of the v0.0.2 roadmap owns accelerator inventory/reservations and the authenticated host-native Metal/Core ML/MLX service. Earlier “reject/defer” entries describe the old core boundary; only private APIs and unsupported fabricated guest passthrough remain excluded.

Status: Phase 27 research-only decision record.

Phase 27 records the current boundary for Apple silicon accelerator work. It does not implement GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator helpers, device exposure, accelerator scheduling, runtime mutation, or capacity guarantees.

## Reviewed Evidence

- Apple `container` is documented as a Linux-container runtime for Mac, optimized for Apple silicon, with each container running in a lightweight virtual machine. The reviewed Apple `container` README and technical overview do not document a GPU, Metal, Core ML, Neural Engine, MPS, or MLX passthrough path for Linux container workloads.
- Apple `containerization` is documented as a Swift package that uses macOS `Virtualization.framework` on Apple silicon and runs Linux containers in lightweight virtual machines.
- Metal is documented as an Apple-platform graphics and compute API for Apple GPUs.
- Core ML is documented as an Apple on-device framework that can use CPU, GPU, and Neural Engine compute units through Apple platform APIs.
- PyTorch MPS is documented as a macOS host path that uses Metal Performance Shaders on MPS-enabled Apple devices.
- MLX is documented for Apple silicon unified memory and CPU/GPU execution on host Apple silicon. Its Linux package path is CPU-only or CUDA, not Apple GPU or Metal guest support.

These points support a conservative current decision: Hostwright-managed Linux containers should not be represented as accelerator-capable unless an official supported access path and disposable local proof exist.

## Decisions

| Path | Decision | Reason | Required Before Reconsidering |
| --- | --- | --- | --- |
| Apple container GPU or Metal passthrough | Reject from current core | No reviewed Apple `container` documentation describes a supported passthrough path for Hostwright-managed Linux containers. | Official supported API, versioned disposable proof, threat model, policy gate, and maintainer approval. |
| PyTorch MPS inside Apple container Linux workloads | Reject from current core | PyTorch MPS is documented as a macOS host Metal path, not as a Linux-container execution path. | Official Linux-container evidence plus local proof on exact macOS and `container` versions. |
| MLX inside Apple container Linux workloads | Reject from current core | MLX's Apple silicon acceleration model depends on host Apple silicon CPU/GPU and unified memory assumptions; reviewed Linux package paths are CPU-only or CUDA. | Official Apple GPU guest support evidence plus local proof. |
| Core ML or ANE inside Apple container Linux workloads | Reject from current core | Core ML and ANE use Apple platform APIs; no reviewed Linux-container path exists. | Public Apple-supported container boundary, threat model, and proof. |
| Host-native accelerator helper or service | Defer to plugin or later prototype | Host-native execution may be the credible path for local inference, embeddings, vector, and RAG workloads, but it adds IPC, local auth, lifecycle, cleanup, data exposure, and audit scope. | Separate issue, Phase 32 policy gate, explicit API boundary, redaction, local auth, audit, sandboxing, cleanup design, and maintainer approval. |
| Read-only host accelerator capability detection | Defer to later prototype | Detection can be useful, but current product behavior must not imply container execution support or scheduler eligibility. | Deterministic local detection design, no runtime mutation, and docs that keep it diagnostic-only. |
| Scheduler accelerator dimensions | Defer and block | No accelerator runtime path, measured capacity, or policy model exists yet. | Phase 32 policy engine, approved accelerator access proof, and measured resource model. |
| Private or undocumented ANE interfaces | Reject | Unsupported interfaces are version-fragile and expand host security risk. | Public supported API only. |

## Workload Boundary

Container workloads remain CPU/container-resource workloads for Hostwright's current scope. Resource intelligence can report host facts and explicit unmeasured dimensions, but it cannot infer accelerator access or production placement.

Potential future local inference, embedding, vector, and RAG workloads should be split into two tracks:

- containerized services that stay inside the current `RuntimeAdapter` and policy boundaries; and
- host-native accelerator services or plugins, if later approved, with their own threat model, lifecycle, redaction, audit, and cleanup controls.

Phase 31 scheduler work may include blocked placeholder explanations for accelerator constraints, but it must not score, reserve, or place workloads on accelerators unless a later implementation issue proves the access path.

## Proof Gate

Any future implementation must provide all of the following before product claims change:

- exact macOS version, Apple `container` version, framework version, model/runtime, and command or API shape;
- evidence that the workload uses the intended accelerator from the intended boundary;
- proof that no image pull, public exposure, unmanaged mutation, or non-Hostwright resource deletion is required;
- security review for memory isolation, side channels, denial of service, host escape surface, local auth, and data exposure;
- operational policy for quota, backoff, fallback, observability, cleanup, diagnostics, and manual recovery;
- public docs that phrase support narrowly by version and proof path.

## Sources

- Apple `container`: <https://github.com/apple/container>
- Apple `container` technical overview: <https://github.com/apple/container/blob/main/docs/technical-overview.md>
- Apple Containerization: <https://github.com/apple/containerization>
- Apple Metal overview: <https://developer.apple.com/metal/>
- Apple Core ML: <https://developer.apple.com/documentation/coreml/>
- Apple PyTorch on Metal: <https://developer.apple.com/metal/pytorch/>
- PyTorch MPS notes: <https://docs.pytorch.org/docs/stable/notes/mps.html>
- MLX install docs: <https://ml-explore.github.io/mlx/build/html/install.html>
- MLX unified memory docs: <https://ml-explore.github.io/mlx/build/html/usage/unified_memory.html>
