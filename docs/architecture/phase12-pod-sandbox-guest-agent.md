# Phase 12 pod-sandbox guest agent

Status: portable HostwrightPodSandbox boundary implemented; the Phase 11
credential-free handoff and authenticated local node-agent producer are
integrated at the guest-agent boundary. Live Apple Container integration
remains deferred while the Phase 09 single-runtime qualification owns the
managed Apple Container lane.

This slice owns the pod-sandbox lifecycle model, the guest-agent protocol v1,
the portable `hostwright-pod-sandbox-guest` executable, and a real subprocess
transport. It does not claim a VM, a Linux namespace, or a CRI/CNI/CSI
adapter.

## Public library boundary

`HostwrightPodSandbox` exposes bounded `PodSandboxID` and `PodSandboxSpec`
values, the `PodSandboxState` and `PodSandboxTransition` vocabularies, and
recovery/snapshot/result values. Identifiers and owners are non-empty,
lowercase bounded names; generations start at one; CPU and memory limits are
bounded before a lifecycle operation is accepted.

`PodSandboxLifecycleStateMachine` is an explicitly owner- and generation-
fenced state machine. A request ID is bound to its transition inputs and an
exact replay returns the prior result without repeating cleanup. A teardown or
cancel creates a tombstone, removes the live record, and permits only bounded
idempotent cleanup replays. A newer generation may create the same sandbox ID;
stale owners and generations cannot act on the tombstone.

The modeled resource accounting is deliberately exact: create owns one
resource, prepare adds one, and running adds one. Recovery accepts only
consistent partial evidence, restores the known state, or removes the
remaining owned resources. This is lifecycle accounting, not an Apple
Container VM claim.

`FilePodSandboxRecoveryStore` durably writes a bounded canonical journal with
live records, tombstones, generation fences, and request replay results. Each
lifecycle mutation persists atomically; a persistence failure rolls the
in-memory transition back and returns an explicit persistence error. A fresh
state machine can therefore replay a request, recover a partial record, reject
an old generation, and repeat teardown without reconstructing success from
missing state.

## Guest protocol v1

The executable protocol is a connected byte stream with an unsigned,
four-byte big-endian payload length. A zero length is invalid. The canonical
JSON payload is sorted-key JSON with unescaped slashes.

| Boundary | Limit |
| --- | ---: |
| Request payload | 64 KiB |
| Response or other frame payload | 1 MiB |
| Deadline | 1–30,000 ms |
| Request/owner/cancellation IDs | 1–128 UTF-8 bytes |
| Stream credit | 0–64 units |
| Capabilities | 0–16 unique values |
| Error text | 512 UTF-8 bytes |

The codec rejects malformed JSON, duplicate or unknown top-level fields,
missing required fields, unsupported versions, non-canonical JSON, invalid
envelope combinations, and over-limit lengths before allocating a payload.
Requests and responses carry the protocol version, kind, request ID,
operation, sandbox ID, owner, generation, bounded deadline, credit, and
capability/error/result fields appropriate to their kind. Cancellation names a
different request ID when it is a cancellation control request. A cancel
request without a target is the lifecycle cancel transition. Credit is a
per-sandbox session grant: the first lifecycle request must grant credit,
later requests may replenish it, each accepted request consumes one unit, and
the response reports the remaining window. Teardown clears the window.

Authentication is a required boundary before dispatch. The production
`ClusterSessionGuestAgentAuthenticationBoundary` and
`GuestAgentNodeAgentTransport` retain only a credential-free Phase 11
`ClusterSessionHandoff`, produced by
`ClusterSessionAuthority.bootstrapConsumer(from:subjectID:nowMilliseconds:)`.
Immediately before every request it calls
`ClusterSessionHandoffAuthorizing.authorize(_:subjectID:nowMilliseconds:)`,
binding `request.ownerID` to the handoff subject. Phase 11 therefore remains
authoritative for strict challenge/proof validation, expiry, revocation
fencing, membership epochs, and monotonic session fencing; no credential,
challenge, proof, or authenticated session is retained by the guest-agent
boundary or copied into the lifecycle wire. The host-side producer encodes the
validated guest request and delegates to
`ClusterNodeAgentLocalTransport.send(handoff:subjectID:operation:payload:nowMilliseconds:timeoutMilliseconds:)`;
that P11 transport reauthorizes the same handoff before launching its local
endpoint. The portable executable itself remains wired to
`UnavailableGuestAgentAuthenticationBoundary` because it has no
authority-backed handoff injection channel; it returns an explicit error
before lifecycle state can change and contains no credential bypass.

## Transport and executable

`GuestAgentProcessTransport` launches the portable executable with two Unix
socket pairs, bounded non-blocking I/O, request/response identity checks, and
deadline/cancellation handling. `GuestAgentNodeAgentTransport` is the
authenticated producer-side bridge: it carries only the handoff and delegates
the canonical guest-agent request payload to the P11 local node-agent
transport. `GuestAgentServer` handles the same framed protocol on supplied
descriptors. The executable supports `--stdio`,
`--stdio --recovery-file <absolute-path>`, and `--version`; recovery paths are
validated file boundaries and are never treated as credentials. Protocol
failures terminate with a generic stderr message and a protocol exit status
without copying request data or credentials into logs.

Focused tests cover malformed and oversized frames, unsupported versions,
canonical/unknown/duplicate fields, unauthenticated dispatch, deadline and
cancellation behavior, credit exhaustion, request replay, invalid
transitions, ownership/generation fencing, restart recovery, partial cleanup,
real fragmented socket-pair dispatch, persistent restart recovery, the real
guest subprocess, and the P12 producer bridge through the P11 local transport.
The authenticated socket-pair tests perform a real Phase 11 P-256
challenge/proof exchange, then exercise the production adapter through Unix
sockets; the shipped executable remains fail-closed until an authority-backed
handoff injection channel is supplied at its boundary.

## Offline rendered Kubernetes scanner

`RenderedKubernetesImporter` is a non-mutating, no-new-dependency scanner for a
deliberately restricted rendered-YAML subset. It accepts multi-document
streams containing only `v1` Pods, `apps/v1` Deployments, and `v1` ClusterIP
Services. The result contains immutable summaries of object identity, labels,
container image references, Deployment replicas/selectors, and Service ports;
it is not a Hostwright manifest translation and cannot invoke Kubernetes,
Helm, the runtime, or the network.

The scanner is fail-closed. A stream with any invalid document returns no
objects. It rejects unsupported API versions, kinds, or fields; aliases,
anchors, merge keys, tags, flow collections, multiline scalars, duplicate map
keys, duplicate object identities, invalid selectors, ambiguous numeric
values, tabs, and malformed indentation. Diagnostics always carry the
one-based document index, original stream line, and structural path. Fixed
limits bound the stream, each document, document count, lines, line bytes,
nesting depth, parsed nodes, collections, and scalar bytes before a summary is
accepted. This scanner is the safe intake boundary for the P12-C08 translation
preview and a later P12-C09 rendered-Helm decision; it does not silently
discard Kubernetes semantics.

## Deterministic translation preview

`RenderedKubernetesTranslationPreview` is the first source-only P12-C08 slice.
It accepts only a successful immutable scanner result and validates the
one-container Pod/Deployment identity projection. The scanner summary does not
retain Kubernetes resource requests or limits, while Hostwright Manifest v3
requires explicit, validated CPU and memory requests and limits for every
executable service. Therefore the current preview fails closed with
`resourceAdmissionUnavailable` and emits neither a Hostwright manifest nor
manifest text; it never invents capacity. A future resource-aware preview must
carry the existing validated resource-admission contract explicitly before it
can emit a manifest. Deployment replica, identity, selector, and service
diagnostics remain bounded and deterministic while this boundary is closed.

The preview deliberately inspects workload identity, image, and replicas only.
Container names and Kubernetes label/selector semantics remain explicitly
reported as untranslated rather than being silently discarded; Deployment
template labels beyond `matchLabels` cannot be recovered from the immutable
scanner summary. The summary does not retain whether a workload declared
`restartPolicy`, so the preview makes no presence or translation claim about
that field. Every error returns neither a manifest nor manifest text.
Fixed object, summary-byte, and output-byte limits also apply when callers
construct public summary values directly instead of obtaining them from the
scanner.

ClusterIP Services do not translate yet. The current Hostwright manifest has
published host endpoints but no internal-only service endpoint construct.
The preview resolves each Service selector within its namespace and reports
missing or ambiguous targets deterministically when retained labels prove that
outcome. The scanner does not retain Deployment template labels beyond the
validated `matchLabels` subset, so any potential template-only match is
reported as indeterminate instead of as a false missing or exact result. Even
an exact target then fails closed with the requested port/protocol mapping. It
never converts a ClusterIP into a localhost or other host publication and
never drops the Service while returning success. This is an offline preview
only: it performs no Helm invocation, network request, runtime mutation, image
pull, credential lookup, CRI call, CNI call, or CSI call, and it is not a
Kubernetes compatibility claim.

## Deferred integration boundary

No Apple Container command, VM, Docker process, daemon, or Phase 08 evidence is
used by this implementation. After the Phase 09 runtime lane is released and
the node-agent transport supplies the Phase 11 session binding, the next slice
is a Linux arm64 build plus one real shared-namespace sandbox and exact cleanup
proof. CRI, CNI, and CSI adapters remain out of scope for this phase.
