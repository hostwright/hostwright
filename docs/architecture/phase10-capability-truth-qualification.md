# Phase 10 Capability-Truth Qualification

Status: bounded contract qualification only. No live accelerator, signing, notarization, or hardware result is claimed by this document.

The separate current-source scheduler qualification is sealed for the G3-G8 contract slice: 1,000,000 generated cases and 10,000 exact-oracle cases completed with zero safety mismatches, 382 intentional optimization-gap fixtures were retained for replay, and the Mac16,8 reference performance receipt recorded 0.917259875 seconds p95. This evidence does not promote `scheduler.optimization`, host-native accelerators, or lifecycle-v3; G13-G15 and live capability evidence remain pending.

The Phase 10 accelerator boundary is evidence-first:

| Surface | Default truth | Required evidence before changing the truth |
| --- | --- | --- |
| Metal, Core ML, or MLX host-native execution | unavailable or pending until a reviewed service proof exists | exact signed service and daemon identity, authenticated workload scope, bounded input/output, quotas, cancellation, revocation, measured usage, and cleanup evidence |
| Linux guest GPU or ANE passthrough | blocked | an official supported public guest API, versioned disposable proof, threat-model review, and maintainer approval |
| XPC service transport | contract-qualified only | role-specific code identity, exact entitlements, request/response binding, cancellation and revocation evidence, and signed local-process qualification |
| Hardware/performance capacity | pending | opt-in physical-Mac run with exact OS, framework, service, model, and cleanup records; no unit test infers capacity |
| Developer ID signing/notarization | pending | credentialed artifact, notarization, stapling, and clean-host verification records |

The negative qualification cells in `Tests/HostwrightAcceleratorTests` and `Tests/HostwrightAcceleratorXPCTests` exercise only exported contract APIs. They prove that guest passthrough cannot be claimed, unavailable evidence remains explicit, identity roles and entitlements cannot be substituted, cancellation/revocation records cannot cross-bind scopes or actors, replay and transport cleanup fail closed, and terminal reservations cannot be replayed with a stale fence.

No test starts or restarts a global Apple service, opens a global socket, mutates an external runtime, or deletes resources outside its exact Phase 10-owned scope. A future live cell must use an explicit Phase 10-only disposable prefix and ownership token, record exact identifiers, and leave the result blocked/pending when signing, hardware, or cleanup prerequisites are absent.

The default XCTest lane is deterministic and does not require Apple signing, notarization, Metal, Core ML, MLX, or an Apple Container installation. Those prerequisites remain opt-in and are not represented as passing evidence by this lane.
