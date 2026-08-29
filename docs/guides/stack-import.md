# Stack-File Import

Status: Phase 28 import-only conversion.

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
- service `command` as an inline array;
- service `environment` as a key-value map with plain or quoted scalar values;
- service `ports` as string entries like `"8080:8080"`;
- service `volumes` only when each source is an explicit host path such as `./data` or `/tmp/data`;
- service `healthcheck.test` only as `["CMD", ...]`;
- service `healthcheck.interval`;
- service `restart` as a scalar or `restart.policy`.

The converted output still runs through Hostwright manifest validation. Invalid names, missing images, unsafe ports, unsafe mounts, plaintext credential-like environment keys, and unsupported restart policies fail closed.

Manifest v3 also requires explicit CPU and memory requests and limits for every executable service. The importer does not infer or translate capacity from a stack file. A stack input without a complete bounded v3 resource mapping therefore fails closed with structured validation diagnostics and emits no manifest text. Author the bounded v3 manifest manually before validating, planning, or applying it.

## Rejected Scope

The importer rejects unsupported or unsafe stack semantics instead of silently dropping them. Rejected fields include:

- `build`;
- `depends_on`;
- `deploy`;
- `networks` and `network_mode`;
- DNS, aliases, hostnames, `extra_hosts`, and `expose`;
- top-level or service-level `secrets` and `configs`;
- `env_file`;
- named volumes;
- shell health checks such as `CMD-SHELL`;
- container names, labels, profiles, and pull policy.

These rejections are intentional. Import output does not imply Docker Compose compatibility, scheduler compatibility, networking compatibility, or runtime compatibility.

## Safe Review Flow

1. Run `hostwright import-stack compose.yaml` without redirecting a failure into `hostwright.yaml`.
2. If it reports the required resource diagnostics, author a bounded Manifest v3 `resources.requests` and `resources.limits` block manually; the importer does not supply it.
3. Review every resulting image, port, volume, environment value, health check, and restart policy.
4. Run `hostwright validate`.
5. Run `hostwright plan`.
6. Apply only through the secure selected state path and plan-hash confirmation gate. The Application Support default is used unless you deliberately pass `--state-db`.

`import-stack` itself never performs step 6.
