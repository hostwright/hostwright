# Compatibility

The published [`v0.0.2` release](https://github.com/hostwright/hostwright/releases/tag/v0.0.2), source `9df19732120d8220ed76a05a234177c483d42dff`, implements the single-Mac scope in [ADR 0015](../design/adr-0015-reduced-local-release.md). The matrix below is bound to its passing focused qualification evidence. Historical development results do not establish support for new source or artifact versions.

## Qualified Release Boundary

| Component | v0.0.2 boundary |
| --- | --- |
| Host | Apple silicon, macOS 26. The release evidence records exact OS builds and hardware; other hardware and OS builds have no separate qualification claim. |
| Lab | One physical M4 Pro for runtime checks and one macOS VM for independent installation/recovery checks. |
| Apple CLI provider | `container` 1.0.0 and 1.1.0, limited to the declared capabilities verified by their focused provider checks. |
| Native provider | Containerization 0.35.0 through the authenticated helper; requires local images. |
| Source toolchain | Swift tools 6.2; record the actual release compiler in provenance. |
| Manifest | Version 3; supported v1/v2 input has a migration preview. |
| Control API | Authenticated persistent local API 2.2; the one-shot companion retains its documented request contract. |
| Runtime Provider API | Version 2; one provider binding per project generation. |
| State | SQLite schema v24, with supported forward migrations and guarded maintenance. |
| Scheduling | Local CPU/memory admission, deterministic placement, and safe pressure deferral. |
| Compose | Explicit import subset with diagnostics for unsupported fields, followed by normal Hostwright lifecycle commands. |
| Desktop | Local manifest selection, status/logs/events, and confirmed up/down/restart. |
| Distribution | Signed v0.0.2 downloads and the vendor tap use the same qualified signed archive. Historical dev.11/dev.12 releases remain unsupported qualification inputs. Official Homebrew acceptance is deferred. |

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

The published matrix is frozen from passing evidence for the exact final-version artifacts; a separate accepted RC is not required. Record provider versions, OS builds, hardware, capability results, and cleanup. One physical host plus a VM establishes neither independent-hardware coverage nor high availability. The [release process](../release/RELEASE_PROCESS.md) defines one complete lifecycle per declared provider, recovery, security and distribution checks.
