# Compatibility

The `0.0.2-dev` line implements the single-Mac scope in [ADR 0015](../design/adr-0015-reduced-local-release.md). Final `v0.0.2` qualification is pending. Historical development results do not establish support for new source or artifact versions.

## Current Development Boundary

| Component | Declared release target |
| --- | --- |
| Host | Apple silicon, macOS 26; record the exact OS build and physical hardware in qualification evidence. |
| Lab | One physical M4 Pro for runtime checks and one macOS VM for independent installation/recovery checks. |
| Apple CLI provider | `container` 1.0.0 and 1.1.0, limited to capabilities that pass conformance. |
| Native provider | Containerization 0.35.0 through the authenticated helper; requires local images. |
| Source toolchain | Swift tools 6.2; record the actual release compiler in provenance. |
| Manifest | Version 3; supported v1/v2 input has a migration preview. |
| Control API | Authenticated persistent local API 2.2; the one-shot companion retains its documented request contract. |
| Runtime Provider API | Version 2; one provider binding per project generation. |
| State | SQLite schema v24, with supported forward migrations and guarded maintenance. |
| Scheduling | Local CPU/memory admission, deterministic placement, and safe pressure deferral. |
| Compose | Explicit import subset with diagnostics for unsupported fields, followed by normal Hostwright lifecycle commands. |
| Desktop | Local manifest selection, status/logs/events, and confirmed up/down/restart. |
| Distribution | Immutable dev.11/dev.12 archives, packages, and vendor tap are unsupported qualification prereleases. RC and GA require new signed artifacts and lifecycle evidence. |

Run `hostwright runtime providers --json` and `hostwright capabilities --json` for the selected build. The CLI and native providers have different image, network, and interactive capabilities; a provider must reject an operation it does not advertise.

Record the environment used for a result:

```bash
hostwright --version
hostwright capabilities --json
sw_vers
uname -m
swift --version
container --version
```

## Explicit Unsupported Results

Unknown or mixed runtime versions, incompatible helper protocols, unsupported fields, and missing capabilities produce errors before mutation. An existing project keeps its provider binding until an explicit migration succeeds. Missing runtime software is acceptable for validation and manifest planning, but blocks runtime workflows and their qualification.

## Permanent Platform Boundaries

Hostwright does not emulate Intel Macs or older macOS versions, use private Apple APIs, expose an unauthenticated public control endpoint, upload diagnostics automatically, or delete unmanaged resources.

Multi-Mac operation, Kubernetes, Docker-client compatibility, host accelerators, and automatic desktop updates are deferred from this release. See [limitations](limitations.md) for command-specific restrictions.

## GA Matrix Rule

Freeze the published matrix from passing evidence for the exact RC and final-version artifacts. Record provider versions, OS builds, hardware, capability results, and cleanup. One physical host plus a VM establishes neither independent-hardware coverage nor high availability. The [release process](../release/RELEASE_PROCESS.md) defines the required cycles, recovery, security, and distribution checks.
