# Devlog 0031: Scheduler And Placement Engine

Date: 2026-07-08

## Changed

- Added a local advisory scheduler model in `HostwrightReconciler`.
- Added explicit scheduler input and output types for workload class, declared memory request, accelerator placeholders, remote-placement blockers, deterministic scores, and explainable reasons.
- Integrated existing local policy decisions into scheduler recommendations.
- Added reconciler XCTest coverage for determinism, policy/port blockers, memory overcommit, accelerator blockers, fairness scoring, remote-placement blockers, and missing memory evidence.
- Updated architecture, limitations, policy, implementation-plan, build-status, requirements, acceptance, and source-traceability docs.

## Boundaries

- No automatic placement.
- No resource reservation.
- No runtime mutation.
- No RuntimeAdapter changes.
- No SQLite access or state writes.
- No daemon scheduling loop.
- No scheduler API.
- No external scheduler compatibility.
- No Kubernetes scheduler behavior.
- No multi-host scheduling or remote placement.
- No DNS, tunnel, cloud, registry, image-pull, or telemetry behavior.
- No GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, host-native accelerator, or accelerator-aware scheduling support.
- No release tags or GitHub Releases.
