# Manifest Reference

The manifest filename is `hostwright.yaml`.

## Current Shape

```yaml
project: api-local

services:
  api:
    image: ghcr.io/example/api:latest
    ports:
      - "8080:8080"
    env:
      APP_ENV: development
    health:
      command: ["curl", "-f", "http://localhost:8080/health"]
      interval: 10s
    restart:
      policy: on-failure
```

Do not use Kubernetes-style `apiVersion`, `kind`, or `metadata` in canonical Hostwright manifests.

## Parser Limitation

Hostwright uses a restricted manifest subset parser, not a general YAML parser.

Supported forms are intentionally narrow:

- top-level `project:`;
- top-level `services:`;
- service maps indented with two spaces;
- scalar `image`;
- inline `command` arrays;
- string-list `ports` and `volumes`;
- string-map `env`;
- nested `health.command`, `health.interval`;
- nested `restart.policy`.

Unsupported YAML features fail closed, including anchors, aliases, tags, merge keys, block scalars, document markers, flow maps, tabs, and arbitrary indentation.

## Validation

Validation currently checks:

- project name is present and DNS-like;
- service names are DNS-like;
- each service has an image;
- image values do not contain whitespace and do not begin with `-`;
- service-level `command` tokens do not begin with `-`;
- ports use `"host:container"` with values from 1 to 65535;
- volumes use `source:/absolute/container/path[:ro|rw]`;
- health command is non-empty when health is present;
- health interval uses seconds like `10s`;
- restart policy is `no`, `on-failure`, or `unless-stopped`.

Validation does not contact registries or Apple container.

Manifest port syntax does not expose a bind-address field in this alpha. Hostwright-created runtime port publishes default to `127.0.0.1` when mapped to Apple container.

Service-level command tokens beginning with `-` are blocked in the current conservative apply scope because Apple container parses image and command positions after its own flags. Health-check command flags are unaffected because Hostwright does not execute health checks in this alpha.
