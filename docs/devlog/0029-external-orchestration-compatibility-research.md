# Devlog 0029: External Orchestration Compatibility Research

Date: 2026-07-08

## Changed

- Added a research-only decision record for CRI, Kubernetes, Docker API, Compose, Testcontainers, attach, exec, log following, port forwarding, scheduler, lifecycle, networking, identity, and state compatibility.
- Updated requirements, acceptance, implementation-plan, build-status, and limitations docs to keep the current compatibility boundary explicit.
- Added a core docs guard test for unsupported-current-support wording.

## Boundaries

- No CRI shim.
- No Kubernetes node behavior.
- No Docker API shim.
- No Testcontainers target behavior.
- No full Compose parity.
- No attach, exec, log-follow, or port-forward compatibility.
- No external scheduler API.
- No runtime mutation.
- No state reads or writes.
- No RuntimeAdapter calls.
- No Apple container commands.
- No dependencies.
- No network calls or image pulls.
- No release tags or GitHub Releases.
