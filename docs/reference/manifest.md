# Manifest Reference

The manifest filename is `hostwright.yaml`.

## Phase 2 Shape

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

Phase 2 uses a restricted Hostwright manifest subset parser, not a general YAML parser.

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
- ports use `"host:container"` with values from 1 to 65535;
- volumes use `source:/absolute/container/path[:ro|rw]`;
- health command is non-empty when health is present;
- health interval uses seconds like `10s`;
- restart policy is `no`, `on-failure`, or `unless-stopped`.

Validation does not contact registries or Apple container.

