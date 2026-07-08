# Manifest Reference

The manifest filename is `hostwright.yaml`.

## Current Shape

```yaml
version: 1
project: api-local
imagePolicy: allow-tags

services:
  api:
    image: ghcr.io/example/api:latest
    ports:
      - "8080:8080"
    env:
      APP_ENV: development
    secretEnv:
      API_TOKEN: keychain://hostwright.api/api-token
    health:
      command: ["curl", "-f", "http://localhost:8080/health"]
      interval: 10s
    restart:
      policy: on-failure
```

Do not use Kubernetes-style `apiVersion`, `kind`, or `metadata` in canonical Hostwright manifests.

## Version Policy

`version: 1` is the current manifest version. New examples and generated starter manifests include it.

Versionless manifests remain accepted during this alpha and are treated as legacy version 1 input. Explicit versions older than 1 or newer than 1 fail closed. Hostwright does not perform automatic manifest upgrade, downgrade, or compatibility conversion.

## Parser Limitation

Hostwright uses a restricted manifest subset parser, not a general YAML parser.

Supported forms are intentionally narrow:

- optional top-level `version: 1`;
- top-level `project:`;
- optional top-level `imagePolicy: allow-tags` or `imagePolicy: require-digest`;
- top-level `services:`;
- service maps indented with two spaces;
- scalar `image`;
- inline `command` arrays;
- string-list `ports` and `volumes`;
- string-map `env`;
- string-map `secretEnv` using `keychain://<service>/<account>` references;
- nested `health.command`, `health.interval`;
- nested `restart.policy`.

Unsupported YAML features fail closed, including anchors, aliases, tags, merge keys, block scalars, document markers, flow maps, tabs, and arbitrary indentation.

Unsupported Kubernetes, Compose, or other orchestrator fields fail closed. This includes `apiVersion`, `kind`, `metadata`, `build`, `depends_on`, `deploy`, `networks`, `network_mode`, `dns`, `dns_search`, `domainname`, `hostname`, `extra_hosts`, `aliases`, `expose`, `configs`, and `secrets`.

`hostwright import-stack <path>` can convert a smaller stack-file subset into this manifest shape. It accepts only project/name, services, service images, inline-array commands, key-value environment maps, string ports, explicit host-path volumes, `healthcheck.test: ["CMD", ...]`, health intervals, and restart policy values that Hostwright already supports. It rejects unsupported stack fields instead of silently dropping them, then runs the normal Hostwright manifest validator on the converted output.

Imported stack files do not become Hostwright manifests automatically. The command prints converted text only; it does not write `hostwright.yaml`, observe runtime, touch state, contact registries, pull images, or imply Docker Compose compatibility.

## Validation

Validation currently checks:

- if `version` is present, it is exactly `1`;
- project name is present and DNS-like;
- service names are DNS-like;
- each service has an image;
- image values do not contain whitespace and do not begin with `-`;
- image values with a digest use `@sha256:<64 lowercase hex characters>`;
- when `imagePolicy: require-digest` is set, every service image uses a digest-pinned reference;
- service-level `command` tokens do not begin with `-`;
- service-level `command` tokens are not empty;
- environment variable keys use shell-safe letters, numbers, and underscores and do not start with a number;
- plaintext credential-like environment keys in `env` are rejected and must move to `secretEnv`;
- `secretEnv` values must use `keychain://<service>/<account>`;
- the same environment key must not appear in both `env` and `secretEnv`;
- ports use `"host:container"` with values from 1 to 65535;
- volumes use `source:/absolute/container/path[:ro|rw]` and do not use host-root or parent-traversal sources;
- health command is non-empty when health is present;
- health interval uses seconds like `10s`;
- restart policy is `no`, `on-failure`, or `unless-stopped`.

Validation does not contact registries or Apple container.

After validation, Hostwright maps accepted manifests into runtime desired state and evaluates local policy decisions for planner safety. Current planner policy decisions explain port conflicts, broad bind blockers, privileged-port warnings, unsafe mounts, and secret redaction. Separate local policy APIs can also explain image-policy failures, unsupported untrusted-manifest fields, secure-exposure blockers, and accelerator blockers without adding runtime side effects. Policy evaluation is local and non-mutating; it does not expand the manifest into Compose parity.

`imagePolicy` is a local manifest validation policy only. The default is `allow-tags`, which accepts tag-based alpha manifests such as `ghcr.io/example/api:latest`. `require-digest` rejects mutable tag-only image references and accepts digest-pinned references:

```yaml
version: 1
project: api-local
imagePolicy: require-digest

services:
  api:
    image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
```

Digest pinning gives Hostwright a stable content identifier string to require before planning. Hostwright does not verify that a digest exists in a registry, does not resolve tags to digests, does not pull images, does not verify signatures or SBOMs, and does not scan vulnerabilities.

Manifest port syntax does not expose a bind-address field in this alpha. Hostwright-created runtime port publishes default to `127.0.0.1` when mapped to Apple container. DNS, service discovery, network aliases, and reverse proxy settings are not manifest features in this release.

Service-level command tokens beginning with `-` are blocked in the current conservative apply scope because Apple container parses image and command positions after its own flags. Health-check command flags are allowed only after the health command name and arguments are accepted by the bounded health-check policy. Health checks are not shell commands and are not container `exec`; Hostwright does not execute host `curl` or `wget` binaries. Current bounded probes parse `curl`, `wget`, `true`, and `false` shaped commands. `curl` is limited to no-output status flags plus one loopback HTTP(S) URL. `wget` is limited to quiet spider mode plus one loopback HTTP(S) URL. Both URL-shaped probes run through Hostwright's in-process URL fetcher. `true` and `false` accept no arguments and are evaluated directly.

## Untrusted Manifests

Treat manifests from third parties as untrusted input. `hostwright validate` and `hostwright plan` are non-mutating gates, but an accepted manifest can still describe images, ports, environment values, paths, and loopback health probe commands that an operator should review before any confirmed apply or daemon run.

Do not place plaintext credentials in manifests. `secretEnv` stores a local reference such as `keychain://hostwright.api/api-token`, not the secret value. Hostwright does not use the live macOS Keychain by default in this phase; apply resolves references only through an injected backend and otherwise fails before mutation. State, events, diagnostics, and plan output redact both resolved values and keychain reference labels.
