# Expected pre-mutation boundaries

These manifests are syntactically valid and must stop before runtime mutation:

- `named-volume.yaml` intentionally references an undeclared named volume.
  Supported named volumes require a matching top-level `volumes` declaration.
- `unavailable-secret.yaml` requires its configured secret backend to be available.
- `unsupported-network.yaml` requests a custom network owned by Phase 07. Strict
  Manifest v2 rejects that field before runtime mutation.

```bash
hostwright up named-volume.yaml --dry-run --output json
hostwright up unavailable-secret.yaml --dry-run --output json
hostwright up unsupported-network.yaml --dry-run --output json
```
