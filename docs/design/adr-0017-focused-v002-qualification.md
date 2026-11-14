# ADR 0017: Focused v0.0.2 release qualification

Status: accepted by the maintainer on 2026-11-13.

## Decision

Ship signed downloads and the vendor tap. Official Homebrew cask acceptance is
outside v0.0.2; #282 is deferred and closes as not planned. This supersedes the
October 8 launch amendment and final qualification budget in ADR 0015.

The active policy is `hostwright.v0.0.2.focused.v1`. It requires five groups:

| Group | Required result |
| --- | --- |
| Source | Targeted regressions and one complete existing suite in trusted staging. |
| Artifact integrity | Signatures, notarization, checksums, provenance, SBOM/licenses, secrets and applicable dependency findings; zero unresolved P0/P1. |
| Installation | Clean VM archive/package installation, reboot, upgrade preserving data, authorized rollback, repair and uninstall preserving data. |
| Working product | One lifecycle per declared provider, status/stats/logs/restart/down, Compose, desktop/keyboard access, state/workload restore, interruption/cancellation, daemon restart, stale-authority refusal and exact owned cleanup preserving unmanaged resources. |
| Documentation | Executed CLI/Compose/desktop quickstarts, accurate compatibility/install claims, core links and the website packages' checks. |

The declared providers remain Apple container 1.0.0/1.1.0 and Containerization
0.35.0 on the tested Apple-silicon/macOS environments. Qualification records exact
hardware and OS builds and establishes no broader compatibility.

Ten-cycle repetition, a separate timed soak, mandatory full sanitizer/fuzz
campaigns and mandatory agent-review receipts are removed. Existing tools remain
available for investigating a relevant failure. Ordinary code review remains.

## Evidence and promotion

Raw reports retain their actual source, version, command results and attachments.
Artifact groups bind the exact staged inventory; resource groups require successful
cleanup. The protected acceptance workflow validates five group reports and emits
`hostwright.promotion-receipt.v3` with the policy identifier. Promotion verifies
that receipt and publishes accepted staged bytes without rebuilding. A local
pass flag supplies no release authority.

Reuse results for unchanged inputs only, preserving their original bindings and
recording the comparison supporting reuse. Do not relabel old runs as fresh final
candidate execution. A product repair requires affected regression checks and new
signed artifacts; repeat artifact-dependent checks on those new bytes. Unchanged
native ingredients may use the existing authenticated checkpoint path.

Historical releases, receipts, failed attempts and signed evidence are preserved.
Missing results, failed cleanup, mismatched source/artifacts, demonstrated data
loss and authorization failures cannot satisfy this policy.

## Verification

Exercise acceptance/export/promotion round trips and rejection of missing groups,
missing outcomes, failed cleanup, mismatched source/inventory, unsafe attachment
paths and changed evidence. Keep focused coverage for reproduced product defects.
