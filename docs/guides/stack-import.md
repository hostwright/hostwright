# Stack-File Import

Status: Phase 28 import-only conversion.

`hostwright import-stack <path>` converts a narrow safe stack-file subset into `hostwright.yaml` text for review. It is non-mutating: it does not write files, create state, observe Apple container, contact registries, pull images, or execute runtime actions.

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
- service `environment` as a key-value map;
- service `ports` as string entries like `"8080:8080"`;
- service `volumes` only when each source is an explicit host path such as `./data` or `/tmp/data`;
- service `healthcheck.test` only as `["CMD", ...]`;
- service `healthcheck.interval`;
- service `restart` as a scalar or `restart.policy`.

The converted output still runs through Hostwright manifest validation. Invalid names, missing images, unsafe ports, unsafe mounts, plaintext credential-like environment keys, and unsupported restart policies fail closed.

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

1. Run `hostwright import-stack compose.yaml > hostwright.yaml`.
2. Review every converted image, port, volume, environment value, health check, and restart policy.
3. Run `hostwright validate`.
4. Run `hostwright plan`.
5. Apply only through the existing explicit state path and plan-hash confirmation gate.

`import-stack` itself never performs step 5.
