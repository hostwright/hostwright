# Phase 32: Policy Engine

## What Changed

- Added `HostwrightPolicy` with deterministic local policy decisions, categories, reason codes, severities, remediation text, and stable detail keys.
- Routed existing planner safety checks through `LocalPolicyEvaluator` without changing the reconciler `PlanIssue` surface.
- Routed cleanup dry-run classification reasons through policy decisions while preserving the existing destructive cleanup gates.
- Added policy evaluator coverage for ports, mounts, images, env/secrets, cleanup, lifecycle, secure exposure, untrusted manifests, and accelerator placeholders.
- Added a bridge test proving the reconciler planning policy still emits the same issue content after policy extraction.

## Boundaries Preserved

- No remote policy service.
- No team workflow or central policy distribution.
- No silent bypass or automatic override.
- No runtime mutation from policy.
- No Apple container shell-out from policy.
- No SQLite access from policy.
- No registry calls, image pulls, scanner/signing dependency, telemetry upload, DNS, tunnel, cloud, GUI, Kubernetes, CRI, Docker API, Compose parity, GPU/ANE/Metal/Core ML/MLX, or accelerator scheduling implementation.
