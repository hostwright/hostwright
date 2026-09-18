# Stack-File Import

Status: v0.0.2 local Compose conversion.

`hostwright import-stack <path>` assesses a narrow safe stack-file subset and either emits a validated `hostwright.yaml` text for review or returns structured diagnostics. It is non-mutating: it does not write files, create state, observe Apple container, contact registries, pull images, or execute runtime actions.

## Command

```bash
hostwright import-stack compose.yaml
hostwright import-stack compose.yaml --output json
```

Text mode prints the converted manifest to stdout. Warnings print to stderr. JSON mode returns the converted manifest and structured warnings, or a validation-style error envelope when import fails.

## Accepted Subset

The importer accepts:

- top-level `name` or `project`;
- top-level `services`;
- service `image`;
- complete service `deploy.resources.reservations` and `deploy.resources.limits` CPU and memory blocks;
- service `command` as an inline array;
- service `environment` as a key-value map with plain or quoted scalar values;
- service `ports` as string entries like `"8080:8080"`;
- service `volumes` only when each source is an explicit host path such as `./data` or `/tmp/data`;
- service `healthcheck.test` only as `["CMD", ...]`;
- service `healthcheck.interval`;
- service `restart` as a scalar or `restart.policy`.

The converted output still runs through Hostwright manifest validation. Invalid names, missing images, unsafe ports, unsafe mounts, plaintext credential-like environment keys, and unsupported restart policies fail closed.

Manifest v3 requires explicit CPU and memory requests and limits for every executable service. The importer maps `deploy.resources.reservations` to `resources.requests` and `deploy.resources.limits` to `resources.limits`. Both blocks must specify both resources, and requests must fit within limits. Missing or unrepresentable values fail closed with structured diagnostics and no manifest text.

CPU values must be normalized positive whole counts, such as `"1"`; fractional CPUs are rejected. Memory values use positive whole amounts with `b`, `k`/`kb`, `m`/`mb`, or `g`/`gb` suffixes, case-insensitively. For this supported subset, `512m` maps to `512MiB` (536,870,912 bytes), and `1g` maps to `1GiB`.

```yaml
name: compose-local
services:
  web:
    image: docker.io/library/python@sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92
    command: ["python3", "-m", "http.server", "8080", "--bind", "0.0.0.0"]
    ports:
      - "18103:8080"
    deploy:
      resources:
        reservations:
          cpus: "1"
          memory: 512m
        limits:
          cpus: "1"
          memory: 512m
```

The resource mapping records local admission requests and provider limits; it does not implement Compose deployment orchestration.

## Rejected Scope

The importer rejects unsupported or unsafe stack semantics instead of silently dropping them. Rejected fields include:

- `build`;
- `depends_on`;
- `deploy` fields other than the supported CPU/memory resource blocks, including replicas, placement, and update policy;
- `networks` and `network_mode`;
- DNS, aliases, hostnames, `extra_hosts`, and `expose`;
- top-level or service-level `secrets` and `configs`;
- `env_file`;
- named volumes;
- shell health checks such as `CMD-SHELL`;
- container names, labels, profiles, and pull policy.

These rejections are intentional. Import output does not imply Docker Compose compatibility, scheduler compatibility, networking compatibility, or runtime compatibility.

## Safe Review Flow

1. Run `hostwright import-stack compose.yaml`. Correct any diagnostics, including incomplete resource blocks.
2. Save the successful converted output to a new manifest file, keeping the source Compose file.
3. Review every resulting image, resource request and limit, port, volume, environment value, health check, and restart policy.
4. Run `hostwright validate hostwright.yaml`.
5. Run `hostwright up hostwright.yaml --dry-run --output json` and review the observed-runtime plan. `hostwright plan` is a read-only manifest plan and does not supply the confirmed lifecycle hash.
6. Execute `hostwright up hostwright.yaml --confirm-plan <planSHA256>` using the exact hash from step 5. The Application Support default is used unless you deliberately pass `--state-db`; use the same state path for planning and execution. If the plan changes, review a new dry-run before confirming.

Check the service with `hostwright status hostwright.yaml --output json`. To stop its owned resources, review `hostwright down hostwright.yaml --dry-run --output json`, then execute `hostwright down hostwright.yaml --confirm-plan <planSHA256>` with that shutdown plan's hash.

`import-stack` itself never performs step 6.
