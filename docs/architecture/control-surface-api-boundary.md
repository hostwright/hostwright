# Control Surface API Boundary

> **Historical boundary, expanded by v0.0.2:** the one-shot local API now includes Phase 04 non-interactive lifecycle parity. Phase 09 implements the persistent authenticated Control API v2 and Phase 14 implements the native GUI with parity.

Status: Historical design record plus current contract for the bounded one-shot Control API v2.

This document defines what a future local GUI or other control surface may depend on. The local process supports the established read commands plus exact-confirmed Phase 04 lifecycle operations through the shared CLI engine. It does not implement a GUI, daemon API, socket or HTTP listener, web dashboard, remote service, background service, or separate runtime mutation path.

## Principles

- The core repository owns local control contracts and safety rules, not visual design.
- A control surface must use `hostwright`/`hostwrightd` commands or the explicit `hostwright-control` subset while preserving the same semantics.
- A control surface must not call Apple container, SQLite, `RuntimeAdapter`, state migrations, cleanup deletion, or health execution directly.
- Every selected state path, manifest path, diagnostics bundle path, plan hash, and cleanup token must be resolved and reviewable; a missing state override means the documented Application Support default, never a request-selected path.
- Redacted Hostwright output remains redacted; a control surface must not reconstruct secrets from manifests, state rows, logs, diagnostic bundles, or issue reports.
- Local-only behavior remains local-only. No telemetry upload, hosted diagnostics, cloud dashboard, browser control plane, or remote mutation is part of this boundary.

## One-Shot API

`hostwright-control` is a local stdin/stdout executable, not a service. Launch configuration fixes the manifest path and optional state-database and team-profile paths:

```bash
hostwright-control --manifest /absolute/hostwright.yaml [--state-db /absolute/state.sqlite] [--team-profile /absolute/team-profile.json]
```

It reads one JSON object no larger than 64 KiB, writes one JSON object no larger than 1 MiB, and exits. Input has a five-second total read deadline. Requests cannot supply paths and cannot select commands outside this fixed Control API v2 subset:

| Operation | Existing command contract | Side-effect boundary |
| --- | --- | --- |
| `plan` | `hostwright plan --output json` | Validates and plans only; no runtime or state access. An explicitly configured team profile is enforced. |
| `status` | `hostwright status --output json` | Uses configured state or the secure default, observes runtime, and can perform compatible path/schema migration, snapshot, and audit writes. It does not mutate runtime. |
| `events` | `hostwright events --output json` | Uses configured state or the secure default and reads event rows only; it does not create or migrate missing state. |
| `recovery` | `hostwright recovery --output json` | Uses configured state or the secure default and reads recovery rows only; it does not create or migrate missing state. |
| `doctor` | `hostwright doctor --output json` | Runs existing safe local checks; no Apple container command or state write. |
| `up`, `down`, `run`, `start`, `stop`, `restart`, `rm`, `update` | Matching lifecycle command with `--output json` | Requires exactly one dry-run or exact plan confirmation and delegates to the shared schema-v7 lifecycle saga. |

Example request and response:

```json
{"apiVersion":2,"requestID":"plan-1","operation":"plan"}
```

```json
{"apiVersion":2,"exitCode":0,"operation":"plan","requestID":"plan-1","result":{"kind":"plan","schemaVersion":2},"success":true}
```

The parser rejects unknown or duplicate fields, unsupported API versions, invalid identifiers and filters, oversized input, and unsupported operations such as `apply` or `cleanup`. Lifecycle input may contain only bounded service names, one dry-run or exact confirmation, provider selection, timeout, and parallelism; `run` requires one service. Launch paths must be absolute existing regular non-symlink files with safe ownership and no group/world write or set-ID bits. The tool validates those path facts before delegating, but it is a same-account local process rather than a capability sandbox.

API-owned failures use `HW-API-001` for invalid requests, `HW-API-002` for unavailable or unsafe configured files, and `HW-API-003` for invalid delegated response framing or execution failure. Existing Hostwright command failures preserve their original error body and exit code inside the response. Usage errors before request processing remain text on stderr with exit code 64.

The API has no interactive streams, apply compatibility, cleanup, logs, diagnostics export, benchmark, extension execution, arbitrary command, or generic mutation operation. It opens no listener, persists no process registration, and grants no authority beyond the invoking account and configured command contracts. It resolves the same documented CLI state default when launch configuration omits a state override; request JSON still cannot select any path.

## Approved Local Data Surfaces

The current approved surfaces are existing command contracts:

| Surface | Approved source | Contract notes |
| --- | --- | --- |
| Project and service input | `hostwright validate`, `hostwright plan --output json`, manifest reference docs | Treat manifests as untrusted until validation succeeds. Show project/service names, images, ports, health, restart, and policy issues without exposing raw secret values. |
| Plans | `hostwright plan --output json` | Use `kind`, `project`, `planHash`, `observationConnected`, `issues`, `drift`, and `actions`. A plan is review data, not mutation authority by itself. |
| Lifecycle confirmation | `hostwright up|down|run|start|stop|restart|rm|update --dry-run` then `--confirm-plan <hash>` | Present the exact current plan and require explicit confirmation. Do not synthesize or cache hashes across runtime observations. `apply` remains an `up` compatibility entry point. |
| Status | `hostwright status [--state-db <path>] --output json` | Use observed/runtime fields only when Hostwright reports observation. Do not infer reachability or health beyond reported data. |
| Interactive operations | `hostwright exec|attach|copy|export|inspect|stats` and `logs --follow` | Use only advertised provider capabilities and the CLI's bounded stream, TTY, path-confinement, cancellation, and redaction contracts. The one-shot API does not expose these streams. |
| Events | `hostwright events [--state-db <path>] --output json` | Use filters and sort options from the CLI. Event rows are local forensic records, not telemetry. |
| Recovery | `hostwright recovery [--state-db <path>] --output json` plus confirmed `resume`/`rollback` | Render exact redacted recovery state. Invoke resume or rollback only with the exact group UUID and persisted plan hash. |
| Cleanup preview | `hostwright cleanup [--state-db <path>] --dry-run` | Render every classification: eligible, ambiguous, stale, running, unknown, blocked, and never-delete. Confirmation authority is limited to the current token. |
| Cleanup confirmation | `hostwright cleanup [--state-db <path>] --confirm-cleanup <token>` | Require explicit operator confirmation and the current dry-run token. Never delete unowned, running, image, volume, network, or ambiguous resources. |
| Diagnostics | `hostwright diagnostics [--state-db <path>] --bundle <path>` | Bundles are local files, refuse overwrite, and may contain sensitive local context even when redacted. A control surface must never upload them automatically. |
| Doctor | `hostwright doctor --output json` | Use as local compatibility and resource-intelligence diagnostics only. Do not present capacity guarantees. |
| Errors | JSON error envelope where supported | Use stable `code`, `exitCode`, `kind`, `message`, and optional `issues`. Text-only commands need explicit future JSON contracts before structured parsing is assumed. |

## Must Never Call Directly

A control surface must not:

- execute `container` or any runtime CLI directly;
- open or mutate Hostwright SQLite databases directly;
- call `RuntimeAdapter` implementations directly;
- bypass manifest validation, local policy, plan-hash confirmation, cleanup dry-run tokens, ownership records, or redaction;
- install launch agents, privileged helpers, shell completions, browser helpers, or background services;
- upload diagnostics, logs, events, manifests, state rows, screenshots, or telemetry;
- implement cloud, tunnel, DNS, multi-host, external orchestrator, accelerator, image cleanup, volume cleanup, or unmanaged cleanup behavior.

## Accessibility Requirements

A future control surface must satisfy these product requirements before implementation is accepted:

- Full keyboard navigation for project selection, command review, plan review, event filtering, diagnostics export, and destructive confirmation flows.
- Visible focus states and deterministic tab order.
- Screen-reader labels for service status, health, drift, policy severity, event severity, cleanup classification, and command result state.
- Status and error states must not rely on color alone.
- Long-running operations must expose progress, cancellation/close behavior where safe, and a final announced result.
- Confirmation flows must display exact plan hashes and cleanup tokens in selectable text.
- Error views must preserve Hostwright error codes and redacted messages.
- Diagnostics and log views must warn that redacted local context can still be sensitive before sharing.

## Handoff Criteria

Before design or frontend implementation starts, the separate owner must have:

- this boundary document and the CLI reference as source of truth;
- fixture examples for plan, lifecycle dry-run/results, status, events, recovery, diagnostics, doctor, cleanup dry-run, and JSON errors;
- accessibility acceptance criteria for keyboard and screen-reader behavior;
- a threat-model review for any action that can invoke apply, cleanup, diagnostics export, or daemon control;
- a clear statement that prototypes must use fixtures until explicit live proof is approved;
- maintainer approval for any further API wrapper, installer, launch agent, background service, website, or GUI repository work.

## Current Sequenced Limitations

- Visual design.
- Frontend implementation.
- GUI code in this repository.
- Web dashboard.
- Cloud dashboard.
- Direct Apple container execution.
- Direct SQLite access.
- Runtime mutation outside existing Hostwright CLI/API gates.
- Persistent API service, socket, or HTTP listener.
- New JSON contracts for text-only commands.
