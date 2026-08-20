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

`hostwright export-stack <manifest> [--output text|json]` parses one bounded
Manifest v3 document and calls the same export boundary. Successful text output
is only the canonical Compose document. JSON output is a sorted-key
`composeExport` envelope with `kind`, `sourcePath`, `schemaVersion`,
`contractVersion`, `succeeded`, `composeText`, and `lossReport`. A loss error
returns the validation exit, leaves standard output empty, emits diagnostics or
the JSON envelope on standard error, and keeps `composeText` null.

`hostwright plan-stack-update <current> <desired> [--output text|json]` parses
two bounded Manifest v3 documents and calls the read-only update planner.
Successful text and JSON output report the same sorted changes. The
`composeUpdatePlan` JSON envelope contains `kind`, `currentPath`, `desiredPath`,
`schemaVersion`, `contractVersion`, `accepted`, `mutatesRuntime`, `changes`, and
`lossReport`. A rejected plan returns the validation exit, leaves standard
output empty, emits the diagnostics or envelope on standard error, and always
has an empty `changes` array.

All three commands are also available through persistent unary Control API routes classified as
non-mutating. Export and update planning carry no idempotency key, state path,
or runtime authority. Export derives its authorization project from the
retained manifest. Update planning parses both retained manifests and requires
the same non-empty project before returning one project UUID; a missing,
ambiguous, or mismatched project fails before execution without consulting
state or runtime.

Export/update manifest path arguments are bounded to 4096 UTF-8 bytes. Before
authorization and execution, the control executor standardizes each path against the
authenticated working directory and reads once per distinct resolved identity.
Repeated strings and dot-segment aliases such as `manifest.yaml` and
`./manifest.yaml` share one immutable, at-most-1-MiB snapshot. Direct update
planning applies the same standard-path identity cache in the invoking working
directory. JSON reports only the bounded normalized argument spellings; it does
not replace them with inferred absolute host paths. These transport routes do
not change the library boundary: `HostwrightCompose` itself never contacts the
Control API.

The canonical subset is intentionally narrow:

- top-level `name` or `project` and `services`;
- service `image`, inline-array `command`, map-form `environment`, string-list
  `ports`, explicit host-path `volumes`, `healthcheck.test` as a `CMD` array,
  `healthcheck.interval`, scalar `restart`, and the four-field capacity block
  described below;
- deterministic service/map ordering and quoted scalar output.

Import delegates parsing and Hostwright manifest validation to
`StackFileImporter`; it does not contact `RuntimeAdapter`, the Docker proxy,
registries, or state. Export and update planning parse local manifest inputs but
do not resolve state or contact `RuntimeAdapter`, the Docker proxy, or
registries. Export refuses Hostwright-only policy, networking, storage,
lifecycle, probe, secret, and structured endpoint semantics that this Compose
subset cannot preserve.

Manifest v3 admission requires explicit CPU and memory requests and limits for
every executable service. The current [Compose Deploy Specification](https://compose-spec.github.io/compose-spec/deploy.html#resources)
defines matching CPU-core and byte-value fields under resource reservations and
limits, so this contract maps only this complete shape:

| Compose | Hostwright Manifest v3 |
| --- | --- |
| `deploy.resources.reservations.cpus` | `resources.requests.cpus` |
| `deploy.resources.reservations.memory` | `resources.requests.memory` |
| `deploy.resources.limits.cpus` | `resources.limits.cpus` |
| `deploy.resources.limits.memory` | `resources.limits.memory` |

All four values are required; capacity is never inferred. CPU accepts a
normalized positive whole decimal count because Manifest v3 represents CPU as
an integer. Fractional, exponent, signed, zero, padded, or overflowing Compose
CPU values are rejected rather than rounded. Memory accepts a normalized
positive integer followed by one of the Compose Specification's documented
[byte-unit names](https://compose-spec.github.io/compose-spec/spec.html#specifying-byte-values):
`b`, `k`, `kb`, `m`, `mb`, `g`, or `gb`. This contract accepts those spellings
case-insensitively and maps them deterministically to binary `B`, `KiB`, `MiB`,
or `GiB`; fractional, unitless, zero, signed, and overflowing values are
rejected. Canonical export quotes CPU and memory values and uses lowercase `b`,
`k`, `m`, or `g`.

Every other `deploy` or `deploy.resources` field, including `pids`, devices,
generic resources, placement, replicas, update/restart policy, and extensions,
is an error. YAML anchors, aliases, merges, inline mappings, and duplicate
capacity declarations are also errors. Direct export/update planning rejects a
partial Hostwright resource model with explicit `HW-COMPOSE-003` losses for its
missing capacity fields. Hostwright-only disk, I/O, network, process,
scheduling/accelerator, `TiB`, or out-of-range memory semantics produce the same
explicit loss instead of being dropped.

## Loss and update planning

Losses have stable `HW-COMPOSE-001` through `HW-COMPOSE-005` codes, a
canonical path, severity, message, optional source line, and optional local
policy reason. Unknown fields and unsupported semantics are errors rather than
warnings so no information is silently discarded.

`HostwrightCompose.planUpdate(current:desired:)` validates and representability-
checks both manifest models, rejects a project-name mismatch before producing
changes, and returns sorted add/remove/update service changes. A resource
change is reported as `deploy.resources`. The plan is read-only
(`mutatesRuntime == false`); execution remains a later slice behind the existing
control and lifecycle boundaries.
