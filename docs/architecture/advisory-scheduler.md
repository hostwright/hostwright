# Advisory Scheduler And Placement Model

Status: Phase 31 local advisory model.

Phase 31 adds a deterministic in-memory advisory scheduler for one local Mac. It filters, scores, and explains local recommendations from explicit desired runtime state, optional observed runtime state, local policy decisions, fixture or local resource reports, and declared workload resource requests.

The scheduler does not mutate runtime state, write SQLite, reserve capacity, preempt workloads, create placements, contact registries, pull images, upload telemetry, call Apple container commands, provide a scheduler API, or perform multi-host placement.

## Implemented Boundary

- Scope: local single-host advisory recommendations only.
- Inputs: `DesiredRuntimeState`, optional `ObservedRuntimeState`, `ResourceIntelligenceReport`, explicit `AdvisoryResourceRequest` values, and `LocalPolicyEvaluator`.
- Output: `AdvisorySchedulingReport` with sorted recommendations, stable reason codes, scores, blockers, warnings, remediations, and `advisoryOnly = true`.
- Memory: declared memory requests are compared with local host physical memory and an advisory budget percentage. Missing memory facts block recommendations; missing service memory requests warn.
- Ports and policy: existing local policy decisions for duplicate desired host ports, observed host-port conflicts, broad bind addresses, privileged ports, unsafe mounts, invalid identities, and secret redaction are carried into scheduler explanations.
- Fairness: workload class counts can lower advisory scores when a declared class exceeds the configured local threshold. This is not operating-system QoS, preemption, or fair-share enforcement.
- Workload classes: `interactiveService`, `backgroundWorker`, `batchJob`, `localAI`, and `unknown` are scoring/explanation inputs only.
- Accelerators: requested accelerator dimensions are blockers. They are not scored or reserved.
- Remote placement: any remote placement requirement is blocked.

## Determinism

Scheduler output is stable for the same inputs:

- policy decisions are sorted by the existing policy ordering;
- reasons sort by severity, category, reason code, policy reason code, stable detail key, and message;
- recommendations sort by status, score, service identity, and instance name;
- scores are pure functions of declared inputs.

## Evidence Boundary

Resource intelligence currently records coarse host facts such as physical memory, active processor count, and thermal state. It does not measure runtime density, workload memory pressure, boot latency, polling overhead, battery behavior, sleep/wake behavior, VM overhead, or production capacity. Scheduler recommendations therefore remain advisory and manual-review-only.

Kubernetes scheduler references inform the general filter-then-score shape, but Hostwright does not implement Kubernetes scheduling semantics, node behavior, topology, taints, tolerations, cluster state, or compatibility.

## Rejected Claims

The advisory scheduler is not:

- automatic placement;
- resource reservation;
- production capacity planning;
- runtime mutation;
- daemon-enforced scheduling;
- multi-host scheduling;
- remote placement;
- external scheduler API compatibility;
- Kubernetes scheduler compatibility;
- accelerator-aware scheduling;
- GPU, ANE, Metal, Core ML, MLX, PyTorch MPS, or host-native accelerator support.

## Sources

- Kubernetes scheduler overview: <https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/>
- Kubernetes resource requests: <https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/>
- Kubernetes scheduling framework configuration: <https://kubernetes.io/docs/reference/scheduling/config/>
- Kubernetes node assignment model: <https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/>
- Kubernetes topology spread constraints: <https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/>
- Kubernetes taints and tolerations: <https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/>
- Apple `ProcessInfo.physicalMemory`: <https://developer.apple.com/documentation/foundation/processinfo/physicalmemory>
- Apple `ProcessInfo` thermal-state guidance: <https://developer.apple.com/documentation/foundation/processinfo>
