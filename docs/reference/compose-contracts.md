# Compose contracts

This is the bounded Phase 13 source-only Compose contract slice. The
executable contract is [`phase13-compose-v1.json`](../../contracts/v0.0.2/phase13-compose-v1.json).
It provides deterministic headless import, export, and update planning around
the existing `HostwrightManifest` and `StackFileImporter` boundaries. It does
not claim full Docker Compose compatibility or execute a workload.

## Public boundary

`HostwrightCompose.importDocument(_:)` accepts the reviewed stack-file subset,
returns canonical Hostwright manifest text, and returns canonical Compose text
for a successful result. `HostwrightCompose.exportDocument(_:)` accepts a
validated manifest model and produces the same canonical Compose form.

Both operations return a versioned result with `schemaVersion: 1`,
`contractVersion: "v1"`, and a `ComposeLossReport`. Use
`ComposeContractJSON.render(_:)` for stable sorted-key JSON output. An error
loss makes the result unsuccessful and its output text is `nil`.

The canonical subset is intentionally narrow:

- top-level `name` or `project` and `services`;
- service `image`, inline-array `command`, map-form `environment`, string-list
  `ports`, explicit host-path `volumes`, `healthcheck.test` as a `CMD` array,
  `healthcheck.interval`, and scalar `restart`;
- deterministic service/map ordering and quoted scalar output.

Import delegates parsing and Hostwright manifest validation to
`StackFileImporter`; it does not contact `RuntimeAdapter`, the Docker proxy,
the Phase 09 Control API, registries, or state. Export refuses Hostwright-only
policy, networking, storage, lifecycle, probe, secret, and structured endpoint
semantics that this Compose subset cannot preserve.

## Loss and update planning

Losses have stable `HW-COMPOSE-001` through `HW-COMPOSE-005` codes, a
canonical path, severity, message, optional source line, and optional local
policy reason. Unknown fields and unsupported semantics are errors rather than
warnings so no information is silently discarded.

`HostwrightCompose.planUpdate(current:desired:)` validates and representability-
checks both manifest models, rejects a project-name mismatch before producing
changes, and returns sorted add/remove/update service changes. The plan is
read-only (`mutatesRuntime == false`); execution remains a later slice behind
the existing control and lifecycle boundaries.
