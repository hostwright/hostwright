# GA readiness — final-version preparation, October 26, 2026

Current source prepares unpublished `0.0.2` artifacts. No supported RC or GA is published, and official `brew install hostwright` is not yet available. Manifest v3, Control API 2.2, state schema v24 and the existing single-Mac CLI, desktop and narrow Compose scope remain unchanged.

The maintainer approved one complete qualification of the final version, replacing the separate accepted-RC prerequisite. All eighteen acceptance gates remain required. Historical RC records retain their exact bindings; no RC outcome becomes final-version evidence.

## Reviewed inputs

[PR #423](https://github.com/hostwright/hostwright/pull/423) adds upstream perf kernel-callchain permission and inode xarray cleanup fixes. Its two independent Linux arm64 builds produced the same 16,151,040-byte image with SHA-256 `d6bfd6eeaf5b4f8af446159df8a00aea5f4c04e3be9222082664f17980d7d607`; these are verified inputs, not release qualification. The [#281 correction](https://github.com/hostwright/hostwright/issues/281#issuecomment-6423790678) records why CVE-2026-98983 is inapplicable to the exact Linux 6.18.55 source. No namespace patch or waiver was added.

The port-reservation, SQLite, isolated TLS fixture and managed-daemon repairs remain included. RC.19 signing/staging stopped during regression, so it produced no accepted signed artifacts. The [RC.20 preparation record](ga-readiness-2026-10-26-rc20.md) remains historical; its separate producer, staging and qualification sequence was superseded before execution. Earlier results retain their source, version, environment and artifact limits.

## Closing order

1. Resolve guest access/agent, clean macOS 26/27 environments, signing, storage and physical-provider access before expensive jobs. Preserve the inaccessible old VM; provision one verified disposable replacement if required, with credentials kept securely outside source and evidence exports.
2. Review the consolidated pins, policy, version and documentation, then freeze the exact clean merged final commit. Keep one eighteen-gate evidence checklist outside source.
3. Run one authenticated exact-source runtime producer and the existing two-build signed/notarized staging. Capture staging's mandatory full source run and compiled inventory, then execute its missing routed cells; do not duplicate a successful full run.
4. Qualify installed CLI, desktop, Compose, update/rollback, reboot and uninstall first, including all twelve VM lifecycle and eight recovery operations. Complete conformance and ten cycles per supported provider, one thirty-minute soak, both full sanitizer lanes, six five-minute fuzz targets and the remaining security, license, provenance, accessibility, documentation and independent-review gates against their exact required bindings.
5. Obtain protected acceptance of all eighteen gates and promote those bytes without rebuilding. Verify public hashes and vendor-tap installation; close implementation/publication issues only against completed evidence.
6. Generate and qualify the official cask from public stable bytes. Submit under current contribution rules with truthful adoption evidence and a request for discretionary consideration. Personal review and maintainer responses requiring human authorship remain human handoffs. Keep #282, #283 and #284 open until official acceptance and fresh plain no-tap installation succeed.

Allow one consolidated repair round after diagnosing a failure. Do not rerun successful checks without invalidated inputs or a missing required result. Start no new repair after 8 p.m. Eastern; stop by 11:59 p.m. Eastern on October 26 with completed work and exact unfinished gates. Resume the same candidate's missing work, preserving valid evidence. If only Homebrew review remains, retain the stable release and stop testing until actionable feedback.

See the [acceptance contract](../reference/release-promotion.md) and [scope decision](../design/adr-0015-reduced-local-release.md).
