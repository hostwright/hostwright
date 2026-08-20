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

`hostwright import-stack <path> --output json` and the unary control route
return that same import result as a sorted-key `composeImport` envelope. Its
top-level fields are `kind`, `sourcePath`, `schemaVersion`, `contractVersion`,
`succeeded`, `manifestText`, `canonicalComposeText`, and `lossReport`; a
success is written to standard output and an unsuccessful import is written to
standard error with the normal validation exit code. An explicit team profile
adds its existing `teamPolicy` binding. Plain-text `import-stack` output
remains the legacy converted-manifest form.

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

Manifest v3 admission additionally requires explicit CPU and memory requests
and limits for every executable service. This source-only slice accepts no
Compose resource mapping: the stack importer intentionally rejects Compose
`deploy` and does not infer capacity. Consequently, every executable Compose
input returns an unsuccessful `HW-COMPOSE-004` import envelope with no manifest
or canonical Compose text. Likewise, a valid Hostwright v3 manifest's resource
block is an explicit `HW-COMPOSE-003` export/update loss; it is never silently
dropped.

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
