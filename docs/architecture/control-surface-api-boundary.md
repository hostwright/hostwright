# Control Surface API Boundary

Status: Phase 21 requirements and API boundary only.

This document defines what a future local GUI or other control surface may depend on. It does not implement a GUI, daemon API, web dashboard, remote service, or new runtime mutation path.

## Principles

- The core repository owns local control contracts and safety rules, not visual design.
- A control surface must use `hostwright`/`hostwrightd` commands or a future explicit Hostwright API that preserves the same semantics.
- A control surface must not call Apple container, SQLite, `RuntimeAdapter`, state migrations, cleanup deletion, or health execution directly.
- Every state path, manifest path, diagnostics bundle path, plan hash, and cleanup token must be explicit and reviewable.
- Redacted Hostwright output remains redacted; a control surface must not reconstruct secrets from manifests, state rows, logs, diagnostic bundles, or issue reports.
- Local-only behavior remains local-only. No telemetry upload, hosted diagnostics, cloud dashboard, browser control plane, or remote mutation is part of this boundary.

## Approved Local Data Surfaces

The current approved surfaces are existing command contracts:

| Surface | Approved source | Contract notes |
| --- | --- | --- |
| Project and service input | `hostwright validate`, `hostwright plan --output json`, manifest reference docs | Treat manifests as untrusted until validation succeeds. Show project/service names, images, ports, health, restart, and policy issues without exposing raw secret values. |
| Plans | `hostwright plan --output json` | Use `kind`, `project`, `planHash`, `observationConnected`, `issues`, `drift`, and `actions`. A plan is review data, not mutation authority by itself. |
| Apply confirmation | `hostwright apply --state-db <path> --confirm-plan <hash>` | Present the exact current plan hash and require explicit operator confirmation before invoking apply. Do not synthesize or cache hashes across runtime observations. |
| Status | `hostwright status --state-db <path> --output json` | Use observed/runtime fields only when Hostwright reports observation. Do not infer reachability or health beyond reported data. |
| Logs | `hostwright logs <service> --state-db <path>` | Logs are bounded, redacted text. No follow, attach, exec, or interactive terminal behavior is approved. |
| Events | `hostwright events --state-db <path> --output json` | Use filters and sort options from the CLI. Event rows are local forensic records, not telemetry. |
| Recovery | `hostwright recovery --state-db <path> --output json` | Render manual recovery hints exactly as redacted Hostwright output. Do not retry or roll back automatically. |
| Cleanup preview | `hostwright cleanup --state-db <path> --dry-run` | Render every classification: eligible, ambiguous, stale, running, unknown, blocked, and never-delete. Confirmation authority is limited to the current token. |
| Cleanup confirmation | `hostwright cleanup --state-db <path> --confirm-cleanup <token>` | Require explicit operator confirmation and the current dry-run token. Never delete unowned, running, image, volume, network, or ambiguous resources. |
| Diagnostics | `hostwright diagnostics --state-db <path> --bundle <path>` | Bundles are local files, refuse overwrite, and may contain sensitive local context even when redacted. A control surface must never upload them automatically. |
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
- fixture examples for plan, status, events, recovery, diagnostics, doctor, cleanup dry-run, and JSON errors;
- accessibility acceptance criteria for keyboard and screen-reader behavior;
- a threat-model review for any action that can invoke apply, cleanup, diagnostics export, or daemon control;
- a clear statement that prototypes must use fixtures until explicit live proof is approved;
- maintainer approval for any new API wrapper, installer, launch agent, background service, website, or GUI repository work.

## Non-Goals

- Visual design.
- Frontend implementation.
- GUI code in this repository.
- Web dashboard.
- Cloud dashboard.
- Direct Apple container execution.
- Direct SQLite access.
- Runtime mutation outside existing Hostwright CLI/API gates.
- New JSON contracts for text-only commands.
