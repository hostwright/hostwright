# CLI Reference

The current CLI provides strict RuntimeAdapter-backed lifecycle, observation, recovery, and local automation surfaces.

## Commands

```bash
hostwright --version
hostwright capabilities [--json | --output text|json]
hostwright runtime providers [--json]
hostwright runtime migrate [path] --to apple-cli|containerization --dry-run [--state-db <path>] [--json | --output text|json]
hostwright runtime migrate [path] --to apple-cli|containerization --confirm-migration <token> [--state-db <path>] [--json | --output text|json]
hostwright paths [--state-db <path>] [--json | --output text|json]
hostwright state integrity [--state-db <path>] [--json | --output text|json]
hostwright state backup [--state-db <path>] [--json | --output text|json]
hostwright state backups [--state-db <path>] [--json | --output text|json]
hostwright state restore --backup <id> --dry-run [--state-db <path>] [--json | --output text|json]
hostwright state restore --backup <id> --confirm-restore <token> [--state-db <path>] [--json | --output text|json]
hostwright state repair --dry-run [--state-db <path>] [--json | --output text|json]
hostwright state repair --confirm-repair <token> [--state-db <path>] [--json | --output text|json]
hostwright state recover [--state-db <path>] [--json | --output text|json]
hostwright secret create <keychain-reference> [--state-db <path>] [--json | --output text|json]
hostwright secret update <keychain-reference> [--state-db <path>] [--json | --output text|json]
hostwright secret list [--json | --output text|json]
hostwright secret check <keychain-reference> [--json | --output text|json]
hostwright secret delete <keychain-reference> [--state-db <path>] [--json | --output text|json]
hostwright registry login <registry> --username <name> [--state-db <path>] [--json | --output text|json]
hostwright registry logout <registry> [--state-db <path>] [--json | --output text|json]
hostwright registry status <registry> [--repository <name> [--action pull|push]...] [--json | --output text|json]
hostwright registry referrers discover|fetch <registry> --repository <name> --subject <digest> [--artifact-type <media-type>] [--offline] [--state-db <path>] [--json | --output text|json]
hostwright registry referrers publish <discovery-uuid> --target-server <registry> --target-repository <name> [--state-db <path>] [--json | --output text|json]
hostwright registry referrers copy <registry> --repository <name> --subject <digest> [--artifact-type <media-type>] --target-server <registry> --target-repository <name> [--state-db <path>] [--json | --output text|json]
hostwright registry referrers retain <discovery-uuid> --owner <id> --expires-at <timestamp> [--state-db <path>] [--json | --output text|json]
hostwright registry referrers release <lease-uuid> --fencing-token <uuid> [--state-db <path>] [--json | --output text|json]
hostwright registry referrers status <discovery-uuid> [--state-db <path>] [--json | --output text|json]
hostwright registry referrers prune <discovery-uuid> --digest <digest> [--confirm-plan <sha256>] [--state-db <path>] [--json | --output text|json]
hostwright registry referrers resume <operation-group-uuid> --confirm-plan <sha256> [--state-db <path>] [--json | --output text|json]
hostwright registry sbom generate <absolute-oci-archive> --manifest <absolute-path> [--service <name>] --server <registry> --repository <name> --format spdx-json|cyclonedx-json [--provenance-descriptor-digest <digest> --provenance-referrer-digest <digest>] [--state-db <path>] [--json | --output text|json]
hostwright registry sbom ingest <discovery-uuid> --manifest <absolute-path> [--service <name>] [--state-db <path>] [--json | --output text|json]
hostwright registry sbom query <absolute-manifest-path> [--service <name>] [--state-db <path>] [--json | --output text|json]
hostwright registry sbom export <absolute-manifest-path> [--service <name>] --format spdx-json|cyclonedx-json --output-path <absolute-new-path> [--state-db <path>] [--json | --output text|json]
hostwright registry sbom resume <operation-group-uuid> --confirm-plan <sha256> [--state-db <path>] [--json | --output text|json]
hostwright registry vulnerability evaluate <discovery-uuid> --digest <report-referrer-digest> --manifest <absolute-path> --cosign <absolute-path> [--service <name>] [--state-db <path>] [--json | --output text|json]
hostwright registry vulnerability status <absolute-manifest-path> [--service <name>] [--state-db <path>] [--json | --output text|json]
hostwright registry vulnerability grant-exception <absolute-approval-path> --manifest <absolute-path> [--state-db <path>] [--json | --output text|json]
hostwright registry vulnerability revoke-exception <exception-uuid> [--state-db <path>] [--json | --output text|json]
hostwright registry vulnerability resume <operation-group-uuid> --confirm-plan <sha256> [--state-db <path>] [--json | --output text|json]
hostwright registry provenance generate <absolute-oci-archive> --record <absolute-build-record> --manifest <absolute-path> [--service <name>] --server <registry> --repository <name> --signer <id> --signing-key-ref <typed-secret-reference> [--state-db <path>] [--json | --output text|json]
hostwright registry provenance verify <discovery-uuid> --digest <provenance-referrer-digest> --manifest <absolute-path> [--service <name>] [--state-db <path>] [--json | --output text|json]
hostwright registry provenance status <absolute-manifest-path> [--service <name>] [--state-db <path>] [--json | --output text|json]
hostwright registry provenance resume <operation-group-uuid> --confirm-plan <sha256> [--signing-key-ref <typed-secret-reference>] [--state-db <path>] [--json | --output text|json]
hostwright image inspect <reference>... [--runtime-provider auto|apple-cli|containerization] [--output text|json]
hostwright image pull <reference> [--platform linux/arm64|linux/amd64] [--offline] [--progress none|plain] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--output text|json]
hostwright image push <reference> [--platform linux/arm64|linux/amd64] [--offline] [--progress none|plain] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--output text|json]
hostwright image tag <source> <target> [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--output text|json]
hostwright image load --input <absolute-path> --reference <expected-reference>... [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--output text|json]
hostwright image save <reference>... --output <absolute-path> [--platform linux/arm64|linux/amd64] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--output text|json]
hostwright image build --context <absolute-path> [--file <absolute-path-beneath-context>] --tag <reference> [--platform linux/arm64|linux/amd64] [--offline] [--no-cache] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--output text|json]
hostwright image delete <reference>... [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--output text|json]
hostwright image prune (--dry-run | --confirm-plan <sha256>) [--maximum-bytes <bytes> --target-bytes <bytes>] [--retain-seconds <0-31536000>] [--max-delete <1-256>] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--output text|json]
hostwright image cache status [--maximum-bytes <bytes>] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--output text|json]
hostwright image cache pin|unpin <managed-reference> [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--output text|json]
hostwright volume list [--project <id>] [--state-db <path>] [--output text|json]
hostwright volume inspect <volume-uuid> [--state-db <path>] [--output text|json]
hostwright volume capacity|health [--state-db <path>] [--output text|json]
hostwright volume recover <volume-uuid> --idempotency-key <key> [--state-db <path>] [--output text|json]
hostwright volume delete <volume-uuid> (--dry-run | --confirm-plan <sha256>) [--state-db <path>] [--output text|json]
hostwright volume prune (--dry-run | --confirm-plan <sha256>) [--state-db <path>] [--output text|json]
hostwright volume snapshot create <volume-uuid> --snapshot-id <uuid> --name <name> [--state-db <path>] [--output text|json]
hostwright volume snapshot list <volume-uuid> [--state-db <path>] [--output text|json]
hostwright volume snapshot inspect|retain|export|restore|delete ...
hostwright volume backup create|list|inspect|verify|retain|restore|delete ...
hostwright migrate preview <path> [--json | --output text|json]
hostwright init
hostwright import-stack <path> [--output text|json] [--team-profile <path>]
hostwright validate [path] [--team-profile <path>]
hostwright plan [path] [--output text|json] [--team-profile <path>]
hostwright status [path] [--state-db <path>] [--output text|json] [--runtime-provider auto|apple-cli|containerization]
hostwright apply [path] [--state-db <path>] --confirm-plan <hash> [--runtime-provider auto|apple-cli|containerization] [--team-profile <path> --approval-record <path>]
hostwright up [path] [--service <name>] [--state-db <path>] (--dry-run | --confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--output text|json]
hostwright down [path] [--service <name>] [--state-db <path>] (--dry-run | --confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--output text|json]
hostwright start [path] [--service <name>] [--state-db <path>] (--dry-run | --confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--output text|json]
hostwright stop [path] [--service <name>] [--state-db <path>] (--dry-run | --confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--output text|json]
hostwright restart [path] [--service <name>] [--state-db <path>] (--dry-run | --confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--output text|json]
hostwright rm [path] [--service <name>] [--state-db <path>] (--dry-run | --confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--output text|json]
hostwright update [path] [--service <name>] [--state-db <path>] (--dry-run | --confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--output text|json]
hostwright run [path] --service <name> [--state-db <path>] (--dry-run | --confirm-plan <hash>) [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--parallelism <1-32>] [--output text|json]
hostwright exec <service> [--manifest <path>] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--tty | --no-tty] [--no-stdin] [--output text|json] -- <command> [args...]
hostwright attach <service> [--manifest <path>] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--tty | --no-tty] [--no-stdin]
hostwright copy (<absolute-host-path> <service:/absolute/container/path> | <service:/absolute/container/path> <absolute-host-path>) [--manifest <path>] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--output text|json]
hostwright export <service> <absolute-destination-path> [--manifest <path>] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--output text|json]
hostwright inspect|stats <service> [--manifest <path>] [--state-db <path>] [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--output text|json]
hostwright logs <service> [path] [--tail <n>] [--follow] [--runtime-provider auto|apple-cli|containerization] [--timeout <seconds>] [--state-db <path>] [--output text|json]
hostwright events [--state-db <path>] [--project <name>] [--type <event>] [--service <name>] [--severity info|warning|error] [--limit <n>] [--sort asc|desc] [--output text|json]
hostwright recovery [--state-db <path>] [--project <name>] [--output text|json]
hostwright recovery resume|rollback --group <uuid> --confirm-plan <hash> [--timeout <seconds>] [--state-db <path>] [--project <name>] [--output text|json]
hostwright diagnostics [--state-db <path>] --bundle <path> [--project <name>] [--manifest <path>]
hostwright cleanup [path] [--state-db <path>] --dry-run [--team-profile <path>]
hostwright cleanup [path] [--state-db <path>] --confirm-cleanup <token> [--team-profile <path> --approval-record <path>]
hostwright benchmark --image <local-image> --samples <3-10> --report <path> --source-commit <40-hex> --source-dirty <true|false> --expected-container-version <version> [--attended-sleep-wake-seconds <15-300>] --confirm-live
hostwright extension check --declaration <absolute-path> --executable <absolute-path> [--output text|json]
hostwright doctor [--state-db <path>] [--json | --output text|json]
hostwright-control --version
hostwright-control --manifest <absolute-path> [--state-db <absolute-path>] [--team-profile <absolute-path>]
hostwright daemon status|install|validate|bootstrap|start|stop|kickstart|upgrade|rollback|disable|repair|uninstall [options]
hostwrightd --foreground|--service --config <hostwright.yaml> [--state-db <path>] [options]
hostwright-dist --version
hostwright-dist install <artifact-source> --prefix <path> [--state-db <path>] --output json
hostwright-dist upgrade <artifact-source> --prefix <path> [--state-db <path>] --output json
hostwright-dist repair <artifact-source> --prefix <path> [--state-db <path>] --output json
hostwright-dist status --prefix <path> --output json
hostwright-dist adopt-legacy --prefix <path> [--state-db <path>] --output json
hostwright-dist recover --prefix <path> --output json
hostwright-dist rollback --prefix <path> --output json
hostwright-dist uninstall-plan --prefix <path> --data-policy <preserve|remove> --output json
hostwright-dist uninstall --prefix <path> --data-policy preserve --output json
hostwright-dist uninstall --prefix <path> --data-policy remove --confirmation <plan-token> --output json
hostwright-dist help
```

## Output Modes

Text output is the default for `hostwright` commands. Installed-lifecycle `hostwright-dist` commands require `--output json`; release and developer-evidence commands retain their documented text/report output.

`capabilities`, `runtime providers`, `runtime migrate`, `paths`, every `state`, `secret`, `registry`, and `image` subcommand, `migrate preview`, `import-stack`, `plan`, `status`, every lifecycle command, non-TTY interactive operations, `events`, `recovery`, `extension check`, and `doctor` accept JSON output where shown above. JSON streaming uses bounded NDJSON frames with base64 payloads. Interactive TTY mode and JSON mode are mutually exclusive. JSON output does not weaken mutation gates.

When JSON mode is requested and the CLI can classify the failure, stderr uses this envelope:

```json
{"code":"HW-CLI-001","exitCode":64,"kind":"error","message":"..."}
```

Manifest failures use an `issues` array with stable Hostwright error codes. Doctor readiness results are normal schema-v2 doctor documents on stdout rather than error envelopes: unsupported or blocked local policy exits 65, failed existing-state integrity exits 66, and an external runtime constraint exits 69. A `hostwright-dist` lifecycle failure requested with `--output json` uses `kind: distributionToolError`, code `HW-DIST-001`, the classified exit code, and a message on stderr.

## `hostwright-control --manifest <absolute-path> ...`

Runs one versioned local JSON request through existing `hostwright` command contracts, writes one JSON response, and exits. It is not a daemon, socket, HTTP server, remote API, or background service.

Launch arguments require an explicit absolute manifest path. Optional `--state-db` and `--team-profile` paths are also fixed at launch; request JSON cannot provide or override any path. Configured files must already exist as regular non-symlink files with safe ownership and mode.

Supported operations are `plan`, `status`, `events`, `recovery`, `doctor`, `up`, `down`, `run`, `start`, `stop`, `restart`, `rm`, `update`, and `image`. Requests use a strict top-level shape:

```json
{"apiVersion":2,"requestID":"request-1","operation":"events","project":"demo","eventType":"apply.failed","service":"api","severity":"error","limit":100,"sort":"desc"}
```

Only `events` accepts all filters. `recovery` accepts only `project`; `plan`, `status`, and `doctor` accept no filters. Input is limited to 64 KiB with a five-second read deadline. Output is limited to one 1 MiB JSON object.

Lifecycle requests accept only `services`, `dryRun`, `confirmPlan`, `runtimeProvider`, `timeout`, and `parallelism`. They require exactly one of `"dryRun": true` or an exact lowercase SHA-256 `confirmPlan`; `run` requires exactly one service. These operations delegate to the same lifecycle planner, saga, provider binding, and result envelopes as the CLI.

Image requests use `"operation":"image"` plus one of `inspect`, `pull`, `push`, `tag`, `load`, `save`, `build`, `delete`, or `prune` in `imageOperation`. The operation-specific image fields map to the same strict CLI parser and durable coordinator. For example:

```json
{"apiVersion":2,"requestID":"image-pull-1","operation":"image","runtimeProvider":"apple-cli","imageOperation":"pull","imageReferences":["registry.example/app:v1"],"imagePlatform":"linux/arm64","imageProgress":"none"}
```

The request cannot provide credentials or arbitrary native options. Mutating image requests use the launch-fixed state database, immutable capability binding, durable intent, post-operation observation, exact ownership, and the same recovery path as the CLI.

Success wraps the delegated CLI JSON under `result`. A delegated CLI failure preserves that command's exit code and JSON body under `error`. Invalid requests, unavailable configured files, and control execution failures use `HW-API-001`, `HW-API-002`, and `HW-API-003` respectively.

Without a configured `--state-db`, state-backed operations use the CLI's secure Application Support default. `status` performs runtime observation plus compatible schema migration, snapshot, and audit writes. `events` and recovery inspection remain read-only and fail instead of creating or migrating a missing database. A confirmed lifecycle request may mutate only through the same exact plan and durable operation gate as its CLI counterpart.

The API deliberately excludes interactive streams, apply compatibility, cleanup, logs, diagnostics export, benchmark, extension execution, arbitrary commands, persistent listeners, and generic mutation endpoints.

## Exit Codes

| Exit code | Category | Typical commands |
| ---: | --- | --- |
| `0` | Success | All commands |
| `64` | Usage | Unsupported flags, missing arguments, refused overwrite, local non-manifest file I/O failure, or invalid distribution lifecycle arguments/path shape |
| `65` | Validation | Missing/unreadable manifest, manifest/profile/approval/extension declaration validation, compatibility failure, invalid distribution evidence, downgrade refusal, or lifecycle version conflict |
| `66` | State unavailable | Selected SQLite state path could not be resolved, opened, migrated, verified, locked, read, backed up, restored, repaired, or recovered; integrity also returns 66 for `degraded`/`unrecoverable` while preserving its report on stdout |
| `69` | Runtime/tool unavailable or evidence blocked | Runtime observation/mutation unavailable, a required distribution subprocess failed, or benchmark/distribution evidence remains blocked |
| `70` | Confirmation mismatch | Plan, cleanup, state restore/repair, approval scope, or approval hash bindings do not match current state |
| `71` | Unsafe operation | Planner/apply policy, state-repair authority boundary, reviewed-local extension policy, or distribution ownership verification blocked execution |
| `72` | Partial failure | Cleanup completed with mixed success/failure, benchmark command/identity/cleanup evidence failed, an extension handshake process/protocol failed, or installed lifecycle/recovery could not complete safely |

## `hostwright --version`

Prints the current development version:

The exact output matches `contracts/v0.0.2/versions.json`. The two immutable
Phase 02 qualification prereleases are `0.0.2-dev.11` at
`7d97d6c9ff878ec567c88e6993d4543ab8f0ad95` and `0.0.2-dev.12` at
`71414005104933d8ee3591e8c91bc831bce2e2a2`. Both belong to the `0.0.2-dev`
development line and neither is a supported release.

The release target is `v0.0.2`. The binary does not report the release version until the GA gate passes.

## `hostwright-dist` release, installed lifecycle, and developer surfaces

The unsigned `build`, `assemble`, `verify`, and `lifecycle` commands remain local development evidence. They deliberately cannot return passing trusted-distribution evidence. `hostwright-dist --version` prints the same product version as the other shipped command tools.

The trusted surface is:

```text
hostwright-dist release --source-root <path> --output-dir <path> --expected-commit <40-hex> --expected-version <semver> --release-tag <v-semver> --application-identity <SHA-1> --installer-identity <SHA-1> --team-id <10-char> --notary-keychain-profile <name> [--format text|json]
hostwright-dist verify-release --release-dir <path> --team-id <10-char> [--format text|json]
hostwright-dist homebrew-formula --release-dir <path> --team-id <10-char> --artifact-url <immutable-https-url> --output <Formula/hostwright.rb> [--format text|json]
```

`release` creates no tag, GitHub release, or tap commit. It writes a new output directory only after all build, signature, notarization, package, Gatekeeper, SBOM, provenance, checksum, detached-CMS, cleanup, and independent-verification stages pass. `verify-release` requires the expected Developer ID team and refuses extra, missing, linked, wrong-mode, wrong-digest, wrong-signer, unsafe archive/package, or evidence-mismatched files. `homebrew-formula` operates only on a fully verified trusted release and only for the exact Hostwright GitHub release URL bound by its manifest.

Text remains the default. `--format json` returns schema-1 `trustedRelease`, `trustedReleaseVerification`, or `homebrewFormula` output with exact commit, artifact descriptors, status, and applicable cleanup/retention evidence. Structured failures use `distributionToolError`; `homebrew-formula --output` remains the formula file path and is never interpreted as an output format.

These commands produced and independently verified the immutable dev.11 and dev.12 qualification releases. The vendor-tap command and signed `.pkg` are available qualification channels; neither is a `v0.0.2` GA support claim. See [Install and Upgrade](install.md) for the exact boundary.

The installed lifecycle accepts either the fully verified trusted release plus its exact team identifier or a verified developer distribution. It exposes `install`, `upgrade`, `repair`, `status`, `adopt-legacy`, `recover`, `rollback`, `uninstall-plan`, and `uninstall`; all require structured JSON output. Upgrade is strict SemVer, repair requires the exact installed version and commit, arbitrary downgrade is refused, and rollback accepts only the one verified immediately prior generation retained by a successful upgrade.

Distribution lifecycle status is `not-installed`, `ready`, or `recovery-required`. A pending durable journal must be resolved with `recover` before another mutation. `uninstall --data-policy preserve` requires no confirmation and retains the bound state database. `remove` requires the exact current plan token and removes only the verified active SQLite file set in addition to owned installed payload. `hostwright-dist` creates no LaunchAgent; it stops/restores only an exact existing Homebrew launchd record and refuses a running unmanaged installed `hostwrightd` rather than terminating it. The separate `hostwright daemon` surface owns `dev.hostwright.daemon` and never adopts the Homebrew record.

The complete artifact-source grammar, prefix policy, JSON contracts, durable checkpoint flow, state behavior, legacy adoption, recovery actions, cleanup boundary, and troubleshooting are in [Installed Distribution Lifecycle](installed-lifecycle.md).

## `hostwright capabilities [--json | --output text|json]`

Prints the current product version, release target, locked contract versions, and a deterministic catalog of stable, experimental, unavailable, and externally blocked capabilities. Each capability names its owning phase, GitHub epic, reason, and required evidence classes.

JSON is the machine-readable current-support source. The command performs no runtime observation, network access, state access, or mutation. It reports what this exact build declares; it does not convert a planned capability into support.

## `hostwright secret ...`

Manages only Hostwright-owned `keychain://<service>/<account>` generic-password items. `create` and `update` read a bounded UTF-8 value from stdin or an attended no-echo terminal; secret values are never accepted in argv. `list` and `check` return metadata only. `delete` verifies exact ownership and item identity before removal.

Mutations persist a redacted schema-v8 intent before touching Keychain. Interrupted operations are inspected with `hostwright recovery` and may be resumed or, for an exactly verified create, rolled back with the existing confirmation-bound recovery command. Recovery re-observes item identity and enters safe hold when replay or compensation cannot be proven without persisting secret bytes.

Manifest workload injection additionally accepts guarded `env-file:///absolute/path#KEY` and `local-file:///absolute/path` references. `external://<provider>/<item>` and `plugin://<provider>/<item>` require an explicitly registered provider. Resolution is authorized for one exact project/resource generation and environment key, and failure occurs before runtime mutation. Resolved values are carried outside argv and never enter Hostwright state or diagnostic output.

## `hostwright registry ...`

`registry login` accepts only an HTTPS registry origin and a bounded username in arguments; it reads the secret from stdin or an attended no-echo terminal. Hostwright probes the registry through bounded TLS transport before storing a schema-versioned credential in one endpoint-derived, non-revealing Keychain account. The create or update uses the schema-v9 durable secret-mutation record. `registry logout` removes only that exact Hostwright-owned item through the same durable boundary.

`registry status` reports the authentication scheme, exact requested and granted scopes, token expiry/refresh availability, API-version header evidence, and credential source. Resolution checks the Hostwright Keychain first, then guarded Docker and OCI auth files with Docker's exact `credHelpers`-before-`credsStore` precedence. Credential helpers receive the exact registry on stdin and only `get` in argv. Basic authorization is TLS-only. Bearer challenges and token responses are bounded, scope escalation is rejected, tokens refresh only at the original HTTPS realm, and redirects are limited to three same-origin HTTPS hops.

`registry referrers` treats signatures, attestations, SBOMs, and provenance as opaque typed OCI artifacts; Gate 6 assigns no trust meaning. Discovery uses the OCI 1.1 referrers API with bounded same-origin pagination and the subject-digest fallback tag only when that truncated tag preserves exact identity; a SHA-512 native-API `404` reports unsupported fallback before any tag request. Fetch verifies every digest, size, media type, graph edge, and root subject before schema-v9 cache publication. Publish and copy persist durable intent before effects, upload children before manifests, observe exact remote content after mutations, use conditional fallback-index updates, and can resume the exact fenced operation group. `retain` and `release` use exact fencing tokens. `prune` first emits an exact plan hash and executes only when the confirmed hash, Hostwright publication proof, inactive lease state, remote manifest, and subject binding all match; it never deletes blobs or unrelated manifests.

`registry trust verify` consumes one complete cached Gate 6 discovery, exact subject-manifest bytes, a validated Manifest v2 `imageTrust` policy, and an absolute cosign executable path. It supports cosign major 3 from v3.0.6, accepts only Sigstore bundle v0.3 message signatures, and verifies the subject on stdin with either an exact keyed authority or exact keyless issuer/identity plus a caller-managed TrustedRoot JSON document. Trust material is copied into a private temporary directory, verifier I/O and time are bounded, and cleanup removes only the exact files created by the verification.

`registry trust status`, `grant-exception`, and `revoke-exception` use schema-v10 immutable verification, subject-manifest, and exception evidence. Exception approvals are strict bounded JSON records bound to one project, service, descriptor digest, reason, approver, approval/expiry timestamps, and idempotency UUID. Lifecycle execution accepts only a current policy/material match with a revalidated graph and subject manifest, or one exact unexpired and unrevoked exception. Recovery revalidates its plan-bound authorization before further effects. The one-shot Control API maps all four operations to the same CLI implementation.

`registry sbom generate` securely inspects an OCI image-layout tar archive, verifies the exact digest-pinned image configuration, manifest, layers, and package-database extraction, and emits a deterministic SPDX 2.3 or CycloneDX 1.6 OCI artifact graph. It does not contact a registry; publish remains the explicit Gate 6 operation. `ingest` accepts only a complete digest-verified Gate 6 graph and persists an immutable schema-v11 record bound to the image descriptor, policy, document, normalized components, SBOM referrer, operation group, and optional provenance descriptor/referrer identities. `query` and `export` re-observe that graph and verify content digests rather than treating state rows or mutation output as truth. Export creates one `0600` file without overwrite and removes only that exact newly created file after failure. Generate, ingest, and export persist bounded non-secret intent; cancellation leaves an interrupted group, and `resume` requires its exact plan hash. The one-shot Control API maps all five operations to the same CLI implementation and exposes no credential fields.

`registry vulnerability evaluate` consumes one complete Gate 6 graph, one exact vulnerability-report referrer digest, a Manifest v2 `imageVulnerability` policy, and the manifest's `imageTrust` policy. It accepts only a bounded `hostwright.dev/image-vulnerability-report/v1` document whose subject, report digest, referrer, database identity/version/update time, generated time, normalized findings, and Sigstore bundle bind exactly. Cosign verifies the report bytes, not merely the image signature. Schema-v12 state stores the canonical passed signature proof, exact bundle digests, verifier identity, trust-material hashes, immutable report evidence, and explainable decisions with candidate, allowlisted, and blocking findings plus stable reason codes.

Severity, minimum age, exploitability, and fix-availability selectors are ANDed. Database staleness or report unavailability follows the explicit fail-open/fail-closed policy, but fail-open never overrides a known matching finding or a report signed under different trust material. The newest `databaseUpdatedAt`, then newest `generatedAt`, is authoritative; equally fresh conflicting reports fail closed. `status` re-observes the exact graph, exact signature bundles, active authority windows, and current trust-material hashes before reevaluating freshness. Exceptions require strict external JSON approval bound to one prior blocked decision, report/referrer, image digest, vulnerability and signature policy hashes, database identity/version, and blocked-findings digest; expiry or revocation takes effect immediately. Evaluate, grant, and revoke persist non-secret durable intent, cancellation becomes an interrupted checkpoint, and `resume` requires the exact plan hash. Lifecycle execution and recovery reload the exact plan-bound manifest and reevaluate current signed evidence before effects. The one-shot Control API maps all five operations to the same implementation and rejects credential fields.

`registry provenance generate` reads a strict bounded build record and a verified local OCI archive, proves the archive root is the exact manifest digest named by the selected service, emits an in-toto Statement v1 with the SLSA provenance v1 predicate, and wraps it in a DSSE Ed25519 envelope. Source, dependency, and material URIs are limited to bounded credential-free HTTPS or URN values; the command model records digests and approved names rather than native argv, host paths, environment values, or secret values. The signing key is resolved only from the exact typed secret-provider reference and is never accepted as a value argument or persisted.

`verify` accepts only the exact provenance referrer from one complete digest-verified Gate 6 graph, revalidates its OCI subject and DSSE envelope, resolves the current Manifest v2 signer material, and checks the exact image, builder, build type, timestamps, materials, reproducibility requirement, signature, and policy hash before immutable schema-v14 persistence. `status`, lifecycle execution, and recovery reload the exact graph and current policy material instead of treating a prior row or generation output as current state. Generation and verification persist bounded redacted intent, interruption requires the exact plan hash, and resumed generation requires the same typed signing-key reference digest. The one-shot Control API maps all four operations to the same CLI implementation and rejects credential values.

No registry credential, username, access token, refresh token, helper stderr, or auth-file content is written to command arguments, state, output, or diagnostics. Registry commands authenticate and report capability; image commands consume only provider-managed authentication and never copy credentials into their request, argv, state, progress, or result.

## `hostwright image ...`

Provides versioned `inspect`, `pull`, `push`, `tag`, `load`, `save`, `build`, `delete`, and `prune` contracts. Apple `container` is the full image provider after exact version and capability negotiation. The Containerization helper exposes structured inspection only; every image mutation reports unavailable before a provider effect.

Mutation stdout is discarded and never establishes success. Each operation is proven from bounded structured image inventory observed before and after the exact native command, including immutable descriptor digests and platform variants. Push, tag, save, delete, and prune bind every source reference to its pre-observed digest and refuse drift before mutation. Load compares the complete pre/post inventory; an undeclared imported reference is rejected and exactly compensated, or held for recovery when restoration cannot be proven. Network operations are HTTPS-only; `--offline` rejects pull, push, and build before observation or mutation. Archive and build paths must be normalized absolute paths, and a build file must remain beneath its context.

Image mutations write a durable `image-lifecycle` intent before effects. Pull, build, tag, and load refuse existing target-reference collisions. Interrupted creation can commit or roll back only when its durable partial-effect evidence binds each newly created reference to the same currently observed digest; missing or changed evidence enters safe hold without adopting or deleting content. Push resumes only when its local source digest is unchanged. Save recovery refuses to infer archive completeness; rollback opens and identity-checks the exact caller-owned regular output before unlinking it.

`delete` requires an exact Hostwright ownership record with the same provider, reference, and digest. A live container reference or digest blocks deletion. `image cache status` reports bounded provider-scoped size, ownership, pin, lease, pressure, stale-reference, and live-reference evidence. `pin` and `unpin` apply only to exact managed references; a desired digest lock remains policy-pinned even after an operator unpin.

`prune --dry-run` deterministically selects only exact Hostwright-owned content after applying size targets, retention, and deletion bounds. Active leases, operator or policy pins, desired digest locks, live references or digests, unmanaged aliases, missing ownership proof, and changed provider observations exclude content. Execution requires the exact plan SHA-256, re-observes before mutation, acquires exclusive fenced leases, invokes only `image delete <exact-reference>...`, verifies absence, and persists recovery accounting. It never invokes a native prune command. Neither delete nor prune accepts `--force`, `--all`, unmanaged content, global cleanup, or automatic background garbage collection.

Result JSON is schema version 1 and includes the provider, provider version, operation UUID, confirmed plan SHA-256, disposition, verified image records, exact created/deleted references and digests, and bounded progress. Cache status, pin, and prune use separate schema-versioned reports with redacted accounting and confirmation evidence. Results contain no mutation stdout, stderr, native argv, credential, token, secret value, or unbounded diagnostic data.

## `hostwright volume ...`

Provides current schema-v16 inspection, capacity, health, recovery, exact deletion/prune, snapshot, and verified backup/restore operations through Storage Provider API v1. The shipped `hostwright-local` provider stores exact Hostwright-owned resources on one Mac. `list`, `inspect`, `capacity`, and `health` are read-only. `recover` requires the persisted idempotency key for the exact interrupted volume operation.

Every destructive operation requires exactly one `--dry-run` or `--confirm-plan <sha256>`. Confirmation binds provider and capability identity, project/resource UUIDs, generation, fence, ownership, attachments, holds, reclaim policy, protection evidence, and current observation. Changed or ambiguous evidence fails before provider mutation. `prune` never invokes global or name-based cleanup.

Snapshots are created, inspected, retained, exported, restored into a new target volume, and exactly deleted through the provider boundary. Backups accept one or more `--volume` values and only typed `--key-ref` secret references. Backup verification checks the complete encrypted catalog and content/metadata hashes. Restore accepts one or more unique `--target <source-uuid>=<new-target-uuid>` mappings and verifies every source before promotion.

The one-shot Control API exposes the same non-interactive volume operations through the same parser and coordinator. See [Storage](storage.md) for Manifest examples, exact command shapes, capacity/pressure behavior, reclaim rules, recovery, and unsupported shared/remote storage boundaries.

## `hostwright runtime providers [--json]`

Negotiates immutable capability snapshots for the Apple CLI and installed Containerization helper without changing state or runtime resources. Output names stable provider IDs, detected CLI/API/helper/framework/protocol versions, macOS and architecture compatibility, per-feature states and reasons, and the canonical capability digest.

An unavailable component remains an explicit unavailable or blocked result. Unknown or mixed versions, an invalid helper handshake, stale component identity, and unsupported architecture never become automatic fallback success.

## `hostwright runtime migrate ...`

`--dry-run` observes the bound source and requested target, checks local-image and capability requirements, and emits planned effects, rollback actions, observation/capability digests, and an exact confirmation token without acquiring an operation or mutating either provider.

`--confirm-migration <token>` recomputes the plan, refuses stale capabilities, observations, ownership, or state, then uses the existing schema-v8 operation group and fencing records to quiesce the source, create and verify the target, preserve UUID identity and prior running state, and advance the provider generation. A failed target verification removes only verified target resources and restores the source when safe. Active operations, ambiguous ownership, collisions, unavailable images, or an incompatible target fail closed.

`status` and `apply` accept `--runtime-provider auto|apple-cli|containerization`. An existing project binding always wins; selecting another provider requires the migration command. For an unbound project, `auto` prefers a compatible Apple CLI provider and selects Containerization only when the CLI is unavailable and the helper is fully capable.

## `hostwright paths [--state-db <path>] [--json | --output text|json]`

Resolves and reports the macOS local layout without creating files. Output includes the selected state path and origin, effective daemon-lock path, Application Support/configuration/runtime/metadata/backup/cache/log/control-socket locations, legacy migration journal path, state/legacy/journal existence flags, permission contract, override precedence, and readiness.

Readiness is one of `ready`, `needs-creation`, `migration-required`, `blocked-conflict`, or `blocked-policy`. Existing path components and migration evidence are opened only for non-mutating validation. Unsafe prospective parents, invalid/ambiguous journals, sidecars, and incompatible legacy ledgers report `blocked-policy`; a valid pending journal reports `migration-required`. `blocked-policy` JSON includes a redacted `policyError`.

State precedence is `--state-db`, then `HOSTWRIGHT_STATE_DB`, then the Application Support default. See [Local Paths, Permissions, and Legacy Migration](local-paths.md) for the complete contract.

## `hostwright state ...`

Provides the complete local state-maintenance surface. These commands never inspect or mutate Apple container runtime resources.

### `state integrity`

Runs bounded SQLite structure, foreign-key, migration-ledger/checksum, required-table, authoritative-record, runtime-observation projection, and health-projection checks. JSON is a versioned `stateIntegrityReport` with `health` equal to `healthy`, `degraded`, or `unrecoverable`, plus the database digest/size, every check, affected-row counts, repairable projection tables, and recommended action.

`healthy` exits 0. `degraded` and `unrecoverable` return the complete report on stdout, a standard `HW-STATE-001` envelope on stderr, and exit 66 so shell gates cannot mistake damage for success. The command is read-only.

### `state backup` and `state backups`

`state backup` uses SQLite's online backup API against the already-migrated selected database. It publishes only after the copied database passes digest, size, schema, SQLite, foreign-key, and logical verification. JSON returns a `stateBackupRecord` containing the opaque `backupID`; do not construct IDs manually.

`state backups` rescans the private catalog and returns every entry. A record with `restorable: false` is evidence, not a restore candidate. Tampered, oversized, hard-linked, strict-JSON-invalid, rollback-only, and incomplete entries remain visible with a verification reason.

The Application Support default stores catalogs under `~/Library/Application Support/Hostwright/backups`. An explicit/environment-selected database uses an identity-derived hidden backup directory beside that database. Catalog directories are `0700`; manifests and databases are `0600`.

### `state restore`

Restore always starts with a dry-run:

```bash
hostwright state restore --backup backup-... --dry-run --json
hostwright state restore --backup backup-... --confirm-restore <confirmationToken> --json
```

The token binds the selected path, backup ID/digest, and current database digest/device/inode. Confirmation after any state change returns `HW-CLI-003`/70. Confirmed restore revalidates under the exclusive state fence, makes a verified pre-restore backup when possible, atomically publishes a same-parent verified stage, clears stale runtime/health projections, appends a maintenance event, and verifies the result. An unreadable original is preserved at the returned `quarantinedDatabasePath`.

Restore refuses source `-wal`, `-shm`, or `-journal` sidecars because filesystem replacement would otherwise be ambiguous. Stop/checkpoint any non-Hostwright SQLite writer first.

### `state repair`

Repair also requires dry-run and confirmation:

```bash
hostwright state repair --dry-run --json
hostwright state repair --confirm-repair <confirmationToken> --json
```

It is available only when integrity is `degraded` exclusively in `observed_services`, `observed_runtime_snapshots`, or `health_check_results`. Dry-run returns exact table row counts. Confirmed repair creates a verified rollback-only pre-repair snapshot, deletes only those declared reconstructible projections in one transaction, appends an event, and requires a final `healthy` report. SQLite, migration, schema, foreign-key, desired-state, ownership, operation, restart, or audit damage is never auto-repaired.

### `state recover`

Resolves a pending restore/repair maintenance journal under the exclusive state fence. Depending on the durable checkpoint, it removes an unpublished stage, restores the displaced original, verifies and finalizes the published replacement, or relies on SQLite transaction rollback. Invalid/tampered journal fields or filesystem state fail closed and preserve evidence. With no journal, the command is idempotent and returns `recovered: false` plus current health.

Do not confuse `hostwright state recover` with `hostwright recovery`: the former repairs the state-database maintenance saga; the latter is read-only inspection of workload operation recovery records.

## `hostwright migrate preview <path> [--json | --output text|json]`

Reads a manifest and prints the deterministic Manifest v2 preview without writing the source, state, or runtime. Explicit v1 has its version replaced, versionless input receives `version: 2`, legacy `health` becomes an equivalent typed liveness probe, and v2 is idempotent. Future or unsupported versions fail closed.

## `hostwright init`

Creates `hostwright.yaml` in the current directory only when the file does not already exist.

`--force` is not implemented; existing manifests are not overwritten.

A local write failure uses `HW-CLI-005` and exit code 64.

Failure example:

```text
HW-CLI-002: hostwright.yaml already exists. init will not overwrite it.
```

## `hostwright import-stack <path> [--output text|json] [--team-profile <path>]`

Reads a narrow safe stack-file subset and prints converted `hostwright.yaml` text to stdout. It does not write files, create `hostwright.yaml`, read or write state, observe Apple container, contact registries, pull images, or mutate runtime resources.

A missing or unreadable stack-file input uses `HW-CLI-005` and exit code 64. JSON mode returns the standard error envelope on stderr.

Supported import input is intentionally small:

- top-level `name` or `project`;
- top-level `services`;
- service `image`;
- service `command` as an inline array;
- service `environment` as a key-value map with plain or quoted scalar values;
- service `ports` as string list entries like `"8080:8080"`;
- service `volumes` only when each source is an explicit host path such as `./data` or `/tmp/data`;
- service `healthcheck.test` only as `["CMD", ...]`;
- service `healthcheck.interval`;
- service `restart` as a scalar policy or `restart.policy`.

Unsupported, unknown, or high-risk stack-file fields fail closed with stable diagnostics. This includes build contexts, named volumes, `secrets`, `configs`, `env_file`, `depends_on`, `deploy`, `network_mode`, `networks`, DNS/service discovery fields, shell health checks, cloud/tunnel semantics, and lifecycle behavior that Hostwright cannot convert safely.

Text success prints the converted manifest and warnings on stderr. JSON success uses:

```json
{
  "kind": "stackImport",
  "sourcePath": "compose.yaml",
  "succeeded": true,
  "manifest": "version: 2\nproject: demo\n...",
  "warnings": []
}
```

JSON import failures use the standard validation exit code `65` and include policy reason codes when the local policy layer classified the rejection:

```json
{
  "kind": "error",
  "code": "HW-MANIFEST-003",
  "exitCode": 65,
  "sourcePath": "compose.yaml",
  "issues": [
    {
      "code": "HW-MANIFEST-003",
      "severity": "error",
      "policyReasonCode": "secureExposureUnsupported",
      "message": "..."
    }
  ]
}
```

Import is conversion-only. It does not imply Docker Compose compatibility or runtime compatibility. Review the converted manifest and run `hostwright validate` and `hostwright plan` before any confirmed apply.

When `--team-profile` is present, the converted manifest is also evaluated against that explicit local profile. Text mode keeps converted manifest stdout parseable and writes profile hashes to stderr; JSON mode adds a `teamPolicy` object. No profile is discovered by default.

## `hostwright validate [path] [--team-profile <path>]`

Reads `hostwright.yaml` by default, or a provided path, and validates the restricted Hostwright manifest shape.

It does not:

- contact registries;
- contact Apple container;
- check whether images exist remotely;
- mutate runtime state.

With an explicit profile, validation also enforces its strict-only requirements and prints the profile and exact manifest SHA-256 hashes. `requireImageDigest` rejects tag-only images even when the manifest defaults to `allow-tags`.

Failure example:

```text
HW-MANIFEST-002: service 'api' must declare an image.
```

## `hostwright plan [path] [--output text|json] [--team-profile <path>]`

Reads and validates the manifest, maps the supported manifest subset into runtime-shaped desired state, runs planning policy checks, and prints a non-mutating dry-run plan.

The output includes a deterministic plan hash, typed issues, typed planned actions, and an explicit execution-unavailable notice.

Runtime observation infrastructure exists behind `RuntimeAdapter`, but `hostwright plan` does not inspect Apple container by default and does not claim resources are running, stopped, healthy, or unhealthy.

With an explicit profile, output includes `profileHash`, `manifestHash`, the exact `planHash` binding, and `approvalRequiredForMutation: true`.

JSON shape:

```json
{
  "kind": "plan",
  "project": "api-local",
  "planHash": "...",
  "teamPolicy": {
    "profileIdentifier": "dev.hostwright.team.local",
    "profileHash": "...",
    "manifestHash": "...",
    "planHash": "...",
    "approvalRequiredForMutation": true
  },
  "observationConnected": false,
  "issues": [],
  "drift": [],
  "actions": []
}
```

## `hostwright apply [path] [--state-db <path>] --confirm-plan <hash> [--team-profile <path> --approval-record <path>]`

`apply` is the compatibility entry point for a confirmed `up` lifecycle plan. Generate the exact hash with `hostwright up --dry-run`; confirmed execution then uses the same durable operation DAG, schema-v8 saga, provider binding, observation, verification, retry, compensation, and recovery behavior as `up`.

When `--team-profile` is selected, `--approval-record` remains mandatory and must bind the exact profile, manifest, current plan, and `apply` scope. `apply` does not add a separate mutation path or loosen lifecycle checks.

Failure example:

```text
HW-CLI-003: Confirmed plan hash does not match current observed plan.
```

## Lifecycle commands

`up`, `down`, `run`, `start`, `stop`, `restart`, `rm`, and `update` compile the manifest, immutable capability snapshot, provider binding, current observation, and ownership state into one deterministic `LifecyclePlan`.

Every invocation requires exactly one of:

- `--dry-run`, which prints the canonical plan and its SHA-256 without acquiring a mutation group; or
- `--confirm-plan <sha256>`, which re-observes and refuses stale capabilities, provider identity, generations, fences, ownership, or plan data before mutation.

The confirmed path persists canonical intent, compensation, verification, node attempts, and idempotency keys before external effects. It executes ready nodes with bounded deterministic parallelism, re-observes between waves, and either succeeds, compensates a proven effect, resumes a durable checkpoint, or enters a precise safe hold. It never deletes by name or adopts an unmanaged collision.

Command semantics:

- `up` converges declared replicas in dependency order and validates that every required image already exists locally;
- `down` stops verified managed resources but preserves them;
- `run` creates one uniquely identified ephemeral instance for exactly one service;
- `start`, `stop`, and `restart` operate only on exact managed instances;
- `rm` removes only verified Hostwright-owned resources in safe reverse dependency order;
- `update` performs the declared rolling or recreate transition, health-gates promotion, retains the prior revision until success, and restores the last verified revision when exact compensation is provable.

Legacy manifest port strings publish to localhost by default. Structured Phase 07 networking executes through exact Hostwright-owned project networks, DNS, ingress, host-access, certificate, policy, and tunnel boundaries; unsupported providers or unavailable exposure modes still fail before mutation. Guarded binds, tmpfs, and declared `hostwright-local` named volumes continue to execute through the Phase 06 storage boundary. Secret references are resolved only when the configured backend is available and never enter plan output, state, logs, or diagnostics.

## Interactive and streaming commands

`exec`, `attach`, `copy`, `export`, `inspect`, `stats`, and `logs --follow` require exact UUID-backed managed identity and a provider capability that passed qualification. Unsupported operations fail before execution instead of using a host-shell fallback.

Streams use 64 KiB chunks, at most 1 MiB queued per stream, bounded diagnostics, backpressure, stdin closure, TTY resize, an allowed signal set, cancellation, and complete process-tree cleanup. JSON streams use NDJSON/base64 frames and cannot be combined with an interactive TTY.

Host copy paths must be absolute and pass descriptor-based no-symlink confinement. Container paths and archive entries reject traversal. `inspect` and `stats` render normalized structured provider results; log follow resumes from bounded provider state after a supported restart without uncontrolled duplication.

## `hostwright status [path] [--state-db <path>] [--output text|json]`

A missing or unreadable manifest is a validation failure (`HW-MANIFEST-004`, exit 65), including in JSON mode; absence is not reported as successful status.

The command validates the manifest, observes Apple container through `RuntimeAdapter`, persists a status observation event and snapshot to the selected state database, and renders desired services against observed lifecycle/health/port facts. Without `--state-db`, the selected database is the secure Application Support default. Status is runtime-non-mutating but writes observation state and may perform compatible state/path migration.

It does not mutate runtime state.

JSON shape:

```json
{
  "kind": "status",
  "manifest": {"path": "hostwright.yaml", "valid": true, "exists": true},
  "runtime": {"observed": true},
  "services": []
}
```

## `hostwright logs <service> [path] [--tail <n>] [--follow] [--runtime-provider <provider>] [--timeout <seconds>] [--state-db <path>] [--output text|json]`

Reads the last log lines for a declared and observed Hostwright-managed service through `RuntimeAdapter`.

Rules:

- default tail is 100 lines;
- maximum tail is clamped to 1000 lines;
- the adapter receives the exact observed runtime identifier rather than recomputing a container name; the selected state path supplies migrated legacy ownership hints;
- log output is redacted before display;
- `--follow` uses the bounded streaming contract and is available only when the selected provider advertises it;
- a `logs.read` event with the exact resource identifier is persisted to the selected state database.

Failure example:

```text
HW-RUNTIME-001: logs requires an observed Hostwright-managed service.
```

## `hostwright events [--state-db <path>] [--project <name>] [--type <event>] [--service <name>] [--severity info|warning|error] [--limit <n>] [--sort asc|desc] [--output text|json]`

Reads the SQLite event ledger from the selected, already-migrated state database and renders events in deterministic timestamp/id order. Selection uses the standard override precedence and Application Support default.

It does not inspect runtime state and does not create or migrate the database as a read side effect.

Filters are applied after project selection and before rendering:

- `--type <event>` matches the event type, such as `cleanup.failed`.
- `--service <name>` matches a service name on event rows that carry one.
- `--severity info|warning|error` matches event severity.
- `--limit <n>` returns the first `n` filtered records in the selected order.
- `--sort asc|desc` defaults to `asc`.

JSON shape:

```json
{
  "kind": "events",
  "stateDatabasePath": "/Users/me/Library/Application Support/Hostwright/state/state.sqlite",
  "filters": {"sort": "asc"},
  "events": []
}
```

## `hostwright recovery [--state-db <path>] [--project <name>] [--output text|json]`

Inspection reads durable operation groups and steps from the selected, already-migrated state database without creating or migrating it. Output distinguishes completed work, resumable work, compensable work, and safe holds, and includes the exact group identity, persisted plan hash, checkpoint, remaining effects, and redacted operator guidance.

`recovery resume` and `recovery rollback` require the exact group UUID and persisted plan SHA-256. They re-observe provider identity, capabilities, generations, fences, ownership, and completed effects before continuing. Resume skips already verified nodes. Rollback applies only precomputed inverse actions whose exact ownership and effect remain provable; otherwise the group stays in safe hold without deleting or fabricating success.

JSON shape:

```json
{
  "kind": "recovery",
  "stateDatabasePath": "/Users/me/Library/Application Support/Hostwright/state/state.sqlite",
  "operationGroups": []
}
```

## `hostwright diagnostics [--state-db <path>] --bundle <path> [--project <name>] [--manifest <path>]`

Writes a local redacted JSON diagnostics bundle to the exact `--bundle` path using exclusive creation and mode `0600`.

The command reads only the selected, already-migrated state database and optional manifest path. If `--manifest` is omitted, the bundle is state-only; it does not discover `hostwright.yaml` from the current directory.

The bundle includes:

- telemetry policy: local-only, no upload;
- state schema/version metadata;
- optional manifest summary;
- redacted events, operations, operation groups, operation group steps, health results, restart policy state, restart recovery records, ownership records, and observed snapshots.

The command does not inspect Apple container, observe runtime state, mutate runtime state, create or migrate a missing database, overwrite an existing bundle path, or upload telemetry.

Example:

```bash
hostwright diagnostics --bundle ./hostwright-diagnostics.json --project api-local
```

## `hostwright cleanup [path] [--state-db <path>] --dry-run [--team-profile <path>]`

Plans cleanup candidates only. A candidate is eligible only when all of these are true:

- an ownership record marks the resource cleanup-eligible;
- the resource type is `container`;
- the runtime identifier is exact and Hostwright-owned;
- the project/service match the manifest;
- live observation shows the service is created, stopped, or exited, not running.

The dry run prints an exact confirmation token and classifies ownership-backed and observed-only resources:

With an explicit profile, the token also binds the profile and manifest hashes. The dry run prints those hashes and requires a new cleanup-scoped approval for confirmed deletion. It does not accept `--approval-record` because review must occur after the exact token is known.

- `eligible`: exact Hostwright-owned created/stopped/exited container covered by the token.
- `ambiguous`: duplicate observed runtime identities make the target unsafe.
- `stale`: ownership exists but no matching live container is observed, or runtime reports it missing.
- `running`: live container is running and is never deleted by cleanup.
- `unknown`: runtime lifecycle is unknown.
- `blocked`: ownership/service/adapter state does not safely match the live observation.
- `never-delete`: cleanup eligibility is disabled, the record is not a container, belongs to another project, is not Hostwright-managed, or is observed without a Hostwright ownership record.

Failure example:

```text
HW-CLI-001: cleanup requires exactly one of --dry-run or --confirm-cleanup <token>.
```

## `hostwright cleanup [path] [--state-db <path>] --confirm-cleanup <token> [--team-profile <path> --approval-record <path>]`

Deletes only `eligible` containers covered by the current cleanup token through `RuntimeAdapter`.

Profile-aware confirmed cleanup requires an approval record bound to the exact profile hash, manifest hash, cleanup token, and `cleanup` scope. Approval never changes eligibility, ownership, lifecycle, or exact-identifier checks.

It never deletes images, volumes, networks, or unmanaged containers and never uses broad flags such as `--all` or `--force`.

If one runtime delete fails after another succeeds, the process exits with code `72` and preserves successful deletions in the report. If a delete succeeds but success-state persistence fails, the process reports state unavailable and keeps the deletion visible in stdout.

See `docs/reference/team-workflow.md` for the strict JSON schemas and review sequence.

## `hostwright benchmark ... --confirm-live`

Runs an explicitly confirmed local hardware benchmark and writes a schema-v2 JSON report to a path that must not exist. Required inputs bind the report to a source commit, dirty state, local image, sample count, and expected Apple container version.

Before mutation, the command records RuntimeAdapter metadata/capabilities, exact Apple container version, and the requested local image's descriptor digest, selected platform-variant digest, architecture, and OS. Unexpected version, missing local image, non-arm64 variant, or missing cleanup capability stops before creation.

The command performs 3-10 iterations. Each iteration creates a unique labeled `hostwright-v2-bench-...` resource through `RuntimeAdapter`, starts a bounded process, records boot/poll durations and one exact non-streaming stats sample, waits for terminal-state quiescence, deletes only that identifier, and verifies absence. It never pulls the image, uses a default path, writes SQLite, deletes images/volumes, uses broad cleanup, or uploads the report.

`--attended-sleep-wake-seconds <15-300>` keeps the first bounded process available during an operator-attended window. The command does not put the Mac to sleep. It records sleep/wake as observed only when wall time exceeds monotonic uptime by at least two seconds and the exact resource is observable after wake.

Exit behavior is evidence-driven:

- `0`: every dimension was measured and exact cleanup succeeded;
- `69` / `HW-BENCH-002`: one or more capabilities or dimensions are blocked, including an unexecuted attended sleep/wake protocol;
- `72` / `HW-BENCH-003`: a command, version, identity, ownership, report-validation, or cleanup failure occurred.

Blocked and failed runs still write their report when encoding and file output succeed. Missing confirmation or an existing report path is refused before runtime access.

This command records local evidence only. Its values are not capacity, compatibility, efficiency, or comparative performance claims.

## `hostwright extension check --declaration <absolute-path> --executable <absolute-path> [--output text|json]`

Runs one explicit reviewed-local extension protocol handshake. It does not discover, install, register, persist, or invoke extension capabilities.

The declaration is strict JSON with exactly these fields:

```json
{
  "apiVersion": 1,
  "boundaries": ["stateStore", "explicitStatePath", "redaction", "auditTrail", "localOnlyNoUpload", "noRuntimeMutation"],
  "capability": "diagnosticsRead",
  "executableSHA256": "<64 lowercase hex characters>",
  "identifier": "dev.example.extension",
  "kind": "diagnosticsIntegration",
  "protocolVersion": 1,
  "purpose": "Check the reviewed diagnostics extension protocol.",
  "trust": "reviewedLocal"
}
```

The declaration and executable must be caller-owned regular non-symlink files without group/world write permission. The executable must have owner execute permission and match the declared SHA-256. The host evaluates existing extension policy before execution, copies the exact bytes into a private mode-`0500` staging directory, runs the fixed version-1 handshake with a minimal environment and bounded time/output, verifies every response binding, then removes the staged file and directory before returning success.

JSON success includes `kind: extensionHandshake`, `status: ready`, identity, capability, protocol version, declaration/executable digests, measured process duration, and `cleanup: succeeded`. Errors use `HW-EXT-001` for invalid files/declarations/digests, `HW-EXT-002` for policy or trust blockers, and `HW-EXT-003` for process, timeout, output, response, or cleanup failures.

A successful check proves only that the exact reviewed executable completed the exact handshake. The protocol provides no RuntimeAdapter, SQLite, state, secret, networking, tunnel, accelerator, or mutation capability. The process is not an operating-system sandbox: it retains the invoking account's ambient file, process, and network privileges, can invoke absolute-path tools, and can spawn descendants. The operator must review the exact digest rather than treat `reviewedLocal` as a technical confinement guarantee.

## `hostwright doctor [--state-db <path>] [--json | --output text|json]`

Runs the non-mutating local readiness gate. The selected state path follows normal precedence: explicit `--state-db`, `HOSTWRIGHT_STATE_DB`, then the Application Support default.

The checks cover supported hardware/macOS, Apple CLI and service readiness, manifest presence, secure filesystem policy, immutable state integrity, permissions, loopback/external interfaces, code signature and Gatekeeper trust, reclaimable memory and thermal pressure, required tools, local-only telemetry, and the extended resource-intelligence report. Runtime readiness executes only bounded version and structured system-status probes through `RuntimeAdapter`; it does not inventory or mutate runtime resources.

Each check is `ready`, `degraded`, `externally-constrained`, `blocked`, or `unsupported` and includes remediation when it is not ready. Overall readiness is the strictest check. Ready/degraded reports exit 0; external constraints exit 69; unsupported or blocked policy exits 65; an existing state database that passes path policy but fails or cannot safely complete immutable integrity inspection exits 66. A concurrent state writer is retryable and is not reported as proven corruption.

JSON shape:

```json
{
  "kind": "doctor",
  "schemaVersion": 2,
  "readiness": "degraded",
  "hasFailures": false,
  "hasExternalConstraints": false,
  "resourceReport": {
    "measurementMethod": "localProcessInfoSnapshot",
    "memoryPressure": {
      "status": "unmeasured"
    },
    "limits": [
      "No production density or capacity guarantee."
    ]
  },
  "checks": []
}
```

Doctor never creates or migrates state. Existing state must be checkpointed and free of rollback journals and nonempty WAL data; it is opened as an immutable read-only SQLite snapshot, using an existing Hostwright fence without creating one. Identity, content fingerprint, and checkpoint state are revalidated after inspection so concurrent change fails as a retryable inspection error. See [Doctor Checks](doctor-checks.md) for the complete classification, safety boundary, and remediation flow.

## `hostwright daemon ...`

Controls the exact current-user `dev.hostwright.daemon` LaunchAgent. Text is the default; `--json` and `--output text|json` select versioned machine output.

```text
hostwright daemon status
hostwright daemon install --daemon-executable <absolute-hostwrightd> --config <absolute-hostwright.yaml>
hostwright daemon validate|bootstrap|start|stop|kickstart|rollback|disable|repair|uninstall
hostwright daemon upgrade --daemon-executable <absolute-hostwrightd> --config <absolute-hostwright.yaml>
```

Install/upgrade accept no PATH lookup: both paths must be absolute, canonical, securely owned, and securely revalidated immediately before bootstrap. Other operations accept no executable/config override. Pending durable intent makes every mutation except `repair` fail with recovery-required status.

Readiness is `not-installed`, `stopped`, `running`, `disabled`, or `recovery-required`. JSON schema v1 reports the exact label/domain/plist, executable/config generation, process ID when proven, pending operation, changed flag, and stable reason code. Errors use `HW-DAEMON-101` through `HW-DAEMON-106`; unsafe ownership/external-process refusals exit `71`, while incomplete or ambiguous effects exit `72`.

The command never manages the Homebrew service record, project state, distribution payload, runtime resources, or an unmanaged process. See [Daemon](../architecture/daemon.md) for plist, checkpoint, rollback, security, recovery, and cleanup contracts.

## `hostwrightd --foreground|--service --config <path> [--state-db <path>] [options]`

Runs the foreground development daemon loop or the exact managed service loop. Exactly one mode is required. `--service` requires an absolute normalized config and does not accept `--max-iterations`. Foreground mode accepts the documented state environment overrides. Managed service mode ignores inherited environment overrides and, before runtime construction, re-executes the revalidated same binary once when necessary with an exact initial environment containing only `HOME`, a fixed C locale, and the trusted system `PATH`. It uses the standard Application Support state default unless an explicit argument overrides it.

Options:

- `--interval <seconds>`: base reconciliation cadence; default `30`.
- `--jitter <seconds>`: deterministic jitter cap; default `5`.
- `--max-backoff <seconds>`: repeated-error backoff cap; default `300`.
- `--max-iterations <count>`: stop after a bounded number of iterations for development proof.
- `--state-db <path>`: optional absolute state override.
- `--lock-file <path>`: optional absolute lock override. Default state uses `run/hostwrightd.lock`; an explicit/environment state uses a stable hashed lock beneath `run`.

Each iteration validates the manifest, observes runtime through `RuntimeAdapter`, computes a plan, and records daemon events plus operation records in the selected state database. Before the loop, the daemon creates/validates the private runtime layout and acquires the validated `0600` single-instance lock.

Gate 1 does not call `RuntimeAdapter.execute` and does not perform unattended runtime mutation. LaunchAgent creation and lifecycle belong to `hostwright daemon`, not the daemon executable itself.

Shell completion remains research-only in Phase 12. Hostwright does not install shell completions or mutate shell profile files.
