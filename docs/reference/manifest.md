# Manifest Reference

The manifest filename is `hostwright.yaml`.

## Current Shape

```yaml
version: 2
project: api-local
imagePolicy: allow-tags
restartBudget:
  maxAttempts: 10
  window: 300s
maintenance:
  timezone: America/New_York
  maximumDeferral: 86400s
  windows:
    - id: weekly-change
      actions: [create, start, restart, update, remove]
      recurring:
        weekdays: [sunday]
        start: "02:00"
        duration: 7200s

volumes:
  database-data:
    provider: hostwright-local
    capacity: 2GiB
    accessMode: read-write-once
    reclaimPolicy: retain

services:
  api:
    image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    replicas: 1
    platform:
      os: linux
      architecture: arm64
    resources:
      cpus: 2
      memory: 1GiB
    user: 1000
    group: 1000
    workdir: /app
    entrypoint: ["/app/server"]
    command: ["serve"]
    init: true
    ports:
      - "8080:8080"
    volumes:
      - type: volume
        source: database-data
        target: /var/lib/api
    env:
      APP_ENV: development
    secretEnv:
      API_TOKEN: keychain://hostwright.api/api-token
    labels:
      app.example.role: api
    probes:
      startup:
        exec: ["/app/server", "check"]
        interval: 2s
        failureThreshold: 30
      readiness:
        http:
          port: 8080
          path: /health
        interval: 10s
      liveness:
        tcp:
          port: 8080
        interval: 20s
    restart:
      policy: on-failure
      maxAttempts: 3
      window: 300s
      backoff: 60s
      maxBackoff: 300s
      jitter: 0s
      stableRun: 60s
      priority: 0
    update:
      strategy: rolling
      maxSurge: 1
      maxUnavailable: 0
      progressDeadline: 300s
      stableObservation: 30s
    hooks:
      postStart:
        exec: ["/app/server", "warm"]
      preStop:
        exec: ["/app/server", "drain"]
    readOnlyRootFilesystem: true
    shmSize: 64MiB
```

Canonical Hostwright manifests use this versioned Hostwright contract. Phase 12 translates supported Kubernetes resources into Hostwright desired state; it does not overload the canonical file with Kubernetes `apiVersion`, `kind`, or `metadata` fields.

## Version Policy

`version: 2` is the current manifest contract. New examples and generated starter manifests include it explicitly.

Versionless manifests and explicit `version: 1` manifests are legacy input. Execution fails closed with migration guidance. Preview the deterministic read-only conversion without modifying the source:

```bash
hostwright migrate preview hostwright.yaml
hostwright migrate preview hostwright.yaml --json
```

The migration preview inserts or replaces the locked version contract, reports whether input was legacy, and is idempotent for v2. It also converts legacy `health` into an equivalent typed liveness probe. It rejects future versions. Hostwright does not silently downgrade or mutate a manifest during validate, plan, or lifecycle execution.

## Parser Contract

Hostwright pins Yams 6.2.2 only inside `HostwrightManifest` and applies its own strict source-aware decoding contract. Input is limited to:

- one UTF-8 YAML document;
- 1 MiB of UTF-8 input;
- nesting depth 64;
- 100,000 expanded nodes.

Duplicate keys are rejected at every level. Anchors, aliases, merge keys, custom tags, multiple documents, ambiguous scalar coercion, unknown fields, and limit violations fail with stable line, column, and manifest-path diagnostics. Canonical encoding uses fixed field order and lexically sorted maps; every checked-in manifest must satisfy parse → canonical encode → parse equality.

The top-level schema accepts bounded project `restartBudget`, local `maintenance` admission policy, schema-v17 `retention` policy, and exact named-volume declarations. The service schema accepts `image`, `replicas`, `platform`, `resources`, numeric `user` and `group`, `workdir`, `entrypoint`, `command`, `init`, `dependsOn`, `env`, `secretEnv`, `labels`, `ports`, typed bind/named-volume/tmpfs `volumes`, `probes`, legacy `health`, `restart`, `update`, `hooks`, `rosetta`, `virtualization`, `readOnlyRootFilesystem`, and `shmSize`. No accepted field is inert: it maps to desired runtime behavior or fails before mutation when the selected provider cannot execute it.

Unsupported Kubernetes, Compose, or other orchestrator fields fail closed. This includes `apiVersion`, `kind`, `metadata`, `build`, `depends_on`, `deploy`, `networks`, `network_mode`, `dns`, `dns_search`, `domainname`, `hostname`, `extra_hosts`, `aliases`, `expose`, `configs`, and `secrets`.

`hostwright import-stack <path>` can convert a smaller stack-file subset into this manifest shape. It accepts only project/name, services, service images, inline-array commands, key-value environment maps with plain or quoted scalar values, string ports, explicit host-path volumes, `healthcheck.test: ["CMD", ...]`, health intervals, and restart policy values that Hostwright already supports. It rejects unsupported stack fields instead of silently dropping them, then runs the normal Hostwright manifest validator on the converted output.

Imported stack files do not become Hostwright manifests automatically. The command prints converted text only; it does not write `hostwright.yaml`, observe runtime, touch state, contact registries, pull images, or imply Docker Compose compatibility.

## Validation

Validation currently checks:

- `version` is present and exactly `2`;
- project name is present and DNS-like;
- service names are DNS-like;
- each service has an image;
- image values do not contain whitespace and do not begin with `-`;
- image values with a digest use `@sha256:<64 lowercase hex characters>`;
- when `imagePolicy: require-digest` is set, every service image uses a digest-pinned reference;
- replicas are between 1 and 256;
- `platform.os` is `linux`; architecture is `arm64` or capability-gated `amd64`;
- CPU values are positive integers; memory and shared-memory values use normalized units such as `512MiB`;
- `workdir` and container mount targets are normalized absolute container paths;
- entrypoint, command, and hook arrays contain bounded non-empty tokens;
- dependencies name declared services, do not reference themselves, and use `started`, `ready`, or `completed`; lifecycle planning rejects cycles;
- environment variable keys use shell-safe letters, numbers, and underscores and do not start with a number;
- plaintext credential-like environment keys in `env` are rejected and must move to `secretEnv`;
- `secretEnv` values must use a typed `keychain://`, `env-file://`, `local-file://`, `external://`, or `plugin://` reference;
- the same environment key must not appear in both `env` and `secretEnv`;
- labels are bounded and cannot use the reserved `dev.hostwright.` ownership prefix;
- ports use `"host:container"` with values from 1 to 65535; fixed localhost ports cannot collide or be shared by replicas;
- named-volume declarations require normalized capacity, a supported provider, `read-write-once` or `read-only-many`, a declared reclaim policy, and non-reserved labels;
- typed mounts use `bind`, `volume`, or `tmpfs`; bind sources cannot expose host root, devices, traversal, symlinks, or unsafe ownership, and named-volume sources must reference a declaration;
- each probe declares exactly one `exec`, loopback `http`, or loopback `tcp` action with bounded timing and thresholds;
- HTTP/TCP probes reference a declared container port;
- restart policy is `no`, `on-failure`, or `unless-stopped`; optional workload `maxAttempts`, rolling `window`, exponential `backoff`/`maxBackoff`, deterministic `jitter`, `stableRun`, and `priority` are bounded and cross-validated;
- top-level `restartBudget` accepts only project `maxAttempts` from 1 through 1000 and `window` from 1 second through 24 hours;
- top-level `maintenance` requires a named IANA timezone and 1 through 64 uniquely named recurring or one-shot windows; each window admits only an explicit non-empty subset of `create`, `start`, `restart`, `update`, and `remove`;
- recurring maintenance uses unique weekdays, strict local `HH:mm`, and a bounded positive duration; one-shot maintenance uses canonical UTC `startsAt` plus a bounded positive duration; `maximumDeferral` is bounded from 1 second through 30 days;
- top-level `retention`, when present, requires a 60-second-through-365-day recovery horizon, 1 MiB-through-1 TiB maximum/target database sizes with target no larger than maximum, and exactly the ten classes `operations`, `observations`, `events`, `logs`, `metrics`, `traces`, `audits`, `supportEvidence`, `backups`, and `tombstones`;
- every retention class requires `maxAge`, `maxRecords`, and `minimumRecords`; `maxAge` cannot undercut the recovery horizon, record bounds are finite and internally ordered, and up to 64 exact operator/legal holds may bind one class to `*` or one bounded record identity with an optional canonical UTC expiry;
- rolling/recreate update bounds are internally consistent, progress deadlines are positive, and optional `stableObservation` is no longer than the progress deadline;
- Rosetta requires `amd64` plus virtualization.

Validation does not contact registries or Apple container.

`update.stableObservation` defaults to zero. A positive duration requires a readiness or liveness probe. Promotion then requires startup, readiness, liveness, dependency, and stable-observation gates declared by the service. Hostwright persists the first continuously healthy observation and re-runs configured readiness and liveness probes until the duration elapses; a declared probe failure clears the interval. A restart resumes from that persisted checkpoint instead of creating another candidate.

Maintenance scheduling is deterministic in the declared timezone. A nonexistent local time during a daylight-saving transition advances to the first representable matching time; a repeated local time uses its first occurrence only. Elective mutation outside every applicable window is durably deferred with a hard deadline and exact confirmation token. Safety recovery and security-stop actions are never configurable or deferrable. Preview is read-only; cancellation or emergency override applies only to the exact current token, and the daemon revalidates the policy, token, and open interval immediately before lifecycle effects.

After validation, Hostwright maps accepted manifests into runtime desired state and evaluates local policy decisions for planner safety. Current planner policy decisions explain port conflicts, broad bind blockers, privileged-port warnings, unsafe mounts, and secret redaction. Separate local policy APIs can also explain image-policy failures, unsupported untrusted-manifest fields, secure-exposure blockers, and accelerator blockers without adding runtime side effects. Policy evaluation is local and non-mutating; it does not expand the manifest into Compose parity.

`imagePolicy` controls which image reference forms are accepted. The default is `allow-tags`, which accepts tag-based manifests such as `ghcr.io/example/api:latest`. `require-digest` rejects mutable tag-only image references and accepts digest-pinned references:

```yaml
version: 2
project: api-local
imagePolicy: require-digest

services:
  api:
    image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
```

Lifecycle dry-run resolves every selected local image through structured provider evidence and binds the requested reference, immutable descriptor digest, exact Linux platform-variant digest, platform, provider identity, and capability digest into the reviewed plan. Under `allow-tags`, a moved local tag therefore produces a different plan generation and stale confirmation is refused. Under `require-digest`, the supplied descriptor must match the observed descriptor. Execution and rollback reverify the same lock before native create effects.

Lifecycle image resolution remains local and offline: it does not contact a registry or pull missing content. When `imageTrust` is present, execution separately requires previously verified, exact Gate 6 signature evidence or an exact active exception before provider mutation.

`imageTrust` adds an optional offline image-signature trust policy on top of digest pinning:

```yaml
version: 2
project: api-local
imagePolicy: require-digest
imageTrust:
  version: 1
  threshold: 2
  trustedRoot: /Users/dev/.config/hostwright/sigstore-trusted-root.json
  authorities:
    - id: release-key
      type: keyed
      publicKey: /Users/dev/.config/hostwright/release.pub
    - id: ci-oidc
      type: keyless
      issuer: https://token.actions.githubusercontent.com
      identity: https://github.com/example/repo/.github/workflows/release.yml@refs/heads/main
      notBefore: 2026-01-01T00:00:00Z
services:
  api:
    image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
```

`imageTrust` is supported only in Manifest v2 and requires `imagePolicy: require-digest`. The `imageTrust.version` field is locked to `1`. `threshold` must be between 1 and 8, `authorities` must contain between 1 and 8 entries, and threshold cannot exceed the number of declared authorities.

Each authority must declare a unique bounded identifier, a `type`, and only the fields for that type. `keyed` authorities require an absolute normalized `publicKey` path. `keyless` authorities require an exact HTTPS `issuer`, a bounded non-empty `identity`, and a top-level absolute normalized path to a Sigstore TrustedRoot JSON document. Optional `notBefore`, `notAfter`, and `revokedAt` timestamps must be RFC3339 and chronologically ordered.

Canonical encoding sorts `imageTrust.authorities` by `id` and preserves a fixed field order. Unknown `imageTrust` fields fail closed. The manifest text and exact trust-material bytes are bound into the lifecycle confirmation hash. Verification accepts only standardized Sigstore bundle v0.3 message signatures and does not expose user-disableable transparency or identity checks.

`imageSBOM` declares which bounded image-SBOM formats Hostwright may generate and whether exact evidence is required before lifecycle effects:

```yaml
version: 2
project: api-local
imagePolicy: require-digest
imageSBOM:
  version: 1
  requirement: required
  formats:
    - spdx-json
    - cyclonedx-json
services:
  api:
    image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
```

`imageSBOM` is supported only in Manifest v2 with `imagePolicy: require-digest`. Version is locked to `1`; `requirement` is `optional` or `required`; `formats` contains one or both unique values `spdx-json` and `cyclonedx-json`. Canonical encoding sorts formats, and unknown or duplicate fields fail closed. The policy hash and exact image descriptor participate in lifecycle confirmation. A required policy revalidates an immutable schema-v11 binding and its complete Gate 6 graph before execution and again during persisted recovery. Gate 8 binds optional provenance descriptor/referrer identities but does not generate or verify provenance.

`imageVulnerability` declares an explainable signed-report policy:

```yaml
version: 2
project: api-local
imagePolicy: require-digest
imageTrust:
  threshold: 1
  authorities:
    - id: release
      type: keyed
      publicKey: /Users/dev/.config/hostwright/release.pub
imageVulnerability:
  version: 1
  severityThreshold: high
  minimumVulnerabilityAgeSeconds: 86400
  exploitability: known-exploited
  fixAvailability: fix-available
  maximumDatabaseAgeSeconds: 604800
  staleAction: fail-closed
  unavailableAction: fail-closed
  exceptionApproval: required
  allowlist:
    - vulnerabilityID: CVE-2026-0001
      packagePURL: pkg:swift/example@1.0.0
      reason: Not reachable in this deployment
      expiresAt: "2026-12-01T00:00:00Z"
services:
  api:
    image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
```

The policy is Manifest v2 only and requires `imagePolicy: require-digest` plus `imageTrust`. Version is locked to `1`. Severity is `low`, `medium`, `high`, or `critical`; exploitability is `any` or `known-exploited`; fix availability is `any` or `fix-available`; stale and unavailable actions are `fail-open` or `fail-closed`; exception approval is `required` or `disabled`. Allowlist entries bind an exact vulnerability ID and optional package PURL, require a reason and RFC3339 expiry, and are sorted canonically. All bounds, duplicate keys, duplicate allowlist identities, unknown fields, and invalid cross-field combinations fail closed. The policy hash is part of lifecycle confirmation and schema-v12 decisions.

`imageProvenance` declares which signed build provenance may authorize an exact image:

```yaml
version: 2
project: api-local
imagePolicy: require-digest
imageProvenance:
  version: 1
  requirement: required
  builderIDs:
    - urn:hostwright:builder:apple-container
  buildTypes:
    - https://hostwright.dev/build-types/apple-container/v1
  signers:
    - id: release-builder
      publicKey: /Users/dev/.config/hostwright/provenance.pub
      notBefore: "2026-01-01T00:00:00Z"
  maximumAgeSeconds: 604800
  requireReproducible: true
services:
  api:
    image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
```

The policy is Manifest v2 only and requires `imagePolicy: require-digest`. Version is locked to `1`; `requirement` is `optional` or `required`; builder and build-type entries are unique bounded credential-free HTTPS or URN values; signer identifiers are unique; public-key paths are normalized absolute host paths; optional authority timestamps are RFC3339 and chronologically ordered. `maximumAgeSeconds` is between 60 seconds and one year. Canonical encoding sorts builders, build types, and signers, and unknown or duplicate fields fail closed. The policy and current signer material are bound into lifecycle confirmation. A required policy revalidates immutable schema-v14 evidence, the exact Gate 6 graph and referrer, DSSE signature, in-toto/SLSA subject and materials, signer authority, age, and optional reproducibility proof before execution and again during persisted recovery.

Legacy `"host:container"` port strings remain valid and canonicalize to localhost TCP mappings. Structured Phase 07 networking fields execute through exact Hostwright-owned project networks, service aliases, ingress, host access, certificate, policy, and tunnel boundaries; unsupported providers or unavailable exposure modes still fail before mutation.

Typed probes never use a host shell. Exec probes cross the provider’s bounded process-control boundary. HTTP and TCP probes target only implicit container loopback and a declared service port; HTTP follows at most three same-origin loopback redirects. Startup gates readiness and liveness, readiness gates dependencies and rollout promotion, and liveness uses the existing bounded restart policy.

## Untrusted Manifests

Treat manifests from third parties as untrusted input. `hostwright validate`, `hostwright plan`, and lifecycle `--dry-run` are non-mutating gates, but an accepted manifest can still describe images, ports, environment values, paths, hooks, probes, and process arguments that an operator should review before exact plan confirmation.

Do not place plaintext credentials in manifests. `secretEnv` stores a typed provider reference such as `keychain://hostwright.api/api-token`, not the secret value. Confirmed lifecycle execution resolves references only through the exact workload grant and configured provider; absent or mismatched providers fail before operation-group acquisition or runtime mutation. State, events, diagnostics, plans, revisions, and recovery records redact both resolved values and provider references.
