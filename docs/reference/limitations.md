# Limitations

Hostwright targets one Apple silicon Mac running macOS 26. The `0.0.2-dev` CLI, desktop, and Compose-import features remain under release qualification. Use the [compatibility matrix](compatibility.md) and `hostwright capabilities --json` to check a particular build.

## Release scope

The supported target is local workload lifecycle, CPU/memory admission, narrow Compose conversion, and the native desktop console. Multi-Mac orchestration, Kubernetes, Docker API/client compatibility, accelerators, fairness guarantees, automatic preemption, automatic desktop updates, and Homebrew-core submission are deferred under [ADR 0015](../design/adr-0015-reduced-local-release.md).

Development modules for deferred features do not establish product support. Unsupported requests must fail before effects.

## Parser Limitation

Manifest v3 accepts the documented [YAML subset](manifest.md), including resource requests and limits. Unknown fields, unsupported YAML features, future versions, and unsafe paths are rejected. Migration preview converts supported v1/v2 input without modifying its source.

Compose import converts the [declared subset](../guides/stack-import.md) and reports losses or unsupported semantics. Import does not pull images, write state, or start workloads. Review the resulting manifest and use normal plan/confirmation commands to execute it.

## Runtime Truth

The Apple CLI provider supports version-specific 1.0.0/1.1.0 contracts. The Containerization 0.35.0 helper offers a smaller subset and requires images already present locally. Runtime capabilities must be advertised by the selected provider and pass conformance; Hostwright does not guess at unknown output or silently switch an existing project to another provider.

Lifecycle commands require current plan confirmation, policy, ownership, and authority. The daemon reconciles admitted local changes through the same coordinator. Image, network, storage, and interactive operations retain their own capability and ownership checks. No operation grants authority over resources based only on their names.

Image trust, SBOM, vulnerability, and provenance policies validate supplied evidence. Lifecycle execution does not implicitly resolve image tags, fetch registry evidence, run a vulnerability scanner, or perform a build. See the [CLI reference](cli.md) for the separate image and registry commands.

`plan` computes desired-state and policy output without live observation by default. `status` can observe runtime and write state/audit records; it does not prove application reachability. Workload recovery inspection reads operation records, while confirmed `recovery resume` and `recovery rollback` can execute persisted recovery actions.

`doctor` performs bounded local diagnostics. It does not create workloads, request Local Network permission, repair state, or establish performance or capacity. `benchmark` is a separate mutating command with explicit confirmation and owned-resource cleanup; its result applies only to the recorded host and workload.

## State Truth

SQLite schema v24 is the local authority. The default database lives under the current user's Application Support directory; `--state-db` and the documented foreground environment options can select another safe private path. Managed service mode ignores inherited path overrides.

State backups contain SQLite state, not workload files, volumes, Keychain items, or installed binaries. Follow [state recovery](local-recovery.md), [storage backup](storage.md), and [installed lifecycle](installed-lifecycle.md) for those separate recovery paths. Offline maintenance requires the daemon to be stopped. Changed state invalidates restore confirmation.

Support bundles require preview and confirmation and stay local until the operator shares them. They omit raw databases and credential stores. Review the selected content and recipient; [support-bundle documentation](support-bundles.md) covers redaction, encryption, recovery, and deletion.

## Distribution and support

The vendor tap currently distributes unsupported qualification prereleases. Final package signing, notarization, upgrade/rollback, provider, and recovery checks must pass before GA. Automatic application updates and Homebrew-core installation are outside this release.

Hostwright provides no production support SLA, hosted diagnostics, cloud control plane, or high-availability guarantee. Use [SECURITY.md](../../SECURITY.md) to arrange private reporting for vulnerabilities or sensitive diagnostics.
