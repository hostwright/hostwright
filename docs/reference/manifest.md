# Manifest Reference

The manifest filename is `hostwright.yaml`.

## Current Shape

```yaml
version: 2
project: api-local
imagePolicy: allow-tags

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
    update:
      strategy: rolling
      maxSurge: 1
      maxUnavailable: 0
      progressDeadline: 300s
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

The service schema accepts `image`, `replicas`, `platform`, `resources`, numeric `user` and `group`, `workdir`, `entrypoint`, `command`, `init`, `dependsOn`, `env`, `secretEnv`, `labels`, `ports`, bind `volumes`, `probes`, legacy `health`, `restart`, `update`, `hooks`, `rosetta`, `virtualization`, `readOnlyRootFilesystem`, and `shmSize`. No accepted field is inert: it maps to desired runtime behavior or fails before mutation when the selected provider cannot execute it.

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
- `secretEnv` values must use `keychain://<service>/<account>`;
- the same environment key must not appear in both `env` and `secretEnv`;
- labels are bounded and cannot use the reserved `dev.hostwright.` ownership prefix;
- ports use `"host:container"` with values from 1 to 65535; fixed localhost ports cannot collide or be shared by replicas;
- volumes use `source:/absolute/container/path[:ro|rw]` and do not use host-root or parent-traversal sources;
- each probe declares exactly one `exec`, loopback `http`, or loopback `tcp` action with bounded timing and thresholds;
- HTTP/TCP probes reference a declared container port;
- restart policy is `no`, `on-failure`, or `unless-stopped`;
- rolling/recreate update bounds are internally consistent and progress deadlines are positive;
- Rosetta requires `amd64` plus virtualization.

Validation does not contact registries or Apple container.

After validation, Hostwright maps accepted manifests into runtime desired state and evaluates local policy decisions for planner safety. Current planner policy decisions explain port conflicts, broad bind blockers, privileged-port warnings, unsafe mounts, and secret redaction. Separate local policy APIs can also explain image-policy failures, unsupported untrusted-manifest fields, secure-exposure blockers, and accelerator blockers without adding runtime side effects. Policy evaluation is local and non-mutating; it does not expand the manifest into Compose parity.

`imagePolicy` is a local manifest validation policy only. The default is `allow-tags`, which currently accepts tag-based manifests such as `ghcr.io/example/api:latest`. `require-digest` rejects mutable tag-only image references and accepts digest-pinned references:

```yaml
version: 2
project: api-local
imagePolicy: require-digest

services:
  api:
    image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
```

Digest pinning gives Hostwright a stable content identifier string to require before planning. Confirmed lifecycle execution verifies that the exact image exists locally through the selected provider. Hostwright does not contact a registry, resolve tags, pull images, verify signatures or SBOMs, or scan vulnerabilities in Phase 04.

The executable Manifest v2 contract does not expose a bind-address field. Hostwright-created runtime port publishes default to `127.0.0.1`. Phase 04 executes only existing bind mounts; named volumes fail before mutation with a Phase 06 diagnostic. DNS, custom networks, service aliases, ingress, and network policy fail before mutation and remain owned by Phase 07.

Typed probes never use a host shell. Exec probes cross the provider’s bounded process-control boundary. HTTP and TCP probes target only implicit container loopback and a declared service port; HTTP follows at most three same-origin loopback redirects. Startup gates readiness and liveness, readiness gates dependencies and rollout promotion, and liveness uses the existing bounded restart policy.

## Untrusted Manifests

Treat manifests from third parties as untrusted input. `hostwright validate`, `hostwright plan`, and lifecycle `--dry-run` are non-mutating gates, but an accepted manifest can still describe images, ports, environment values, paths, hooks, probes, and process arguments that an operator should review before exact plan confirmation.

Do not place plaintext credentials in manifests. `secretEnv` stores a local reference such as `keychain://hostwright.api/api-token`, not the secret value. Confirmed lifecycle execution resolves references only through the configured backend and otherwise fails before operation-group acquisition or runtime mutation. State, events, diagnostics, plans, revisions, and recovery records redact both resolved values and keychain reference labels.
