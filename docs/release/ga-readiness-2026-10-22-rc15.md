# GA readiness — RC.15 preparation, October 22, 2026

Current source prepares `0.0.2-rc.15`. No supported RC or GA has been published.
The exact candidate source freeze and signed artifacts remain pending.
Manifest v3, Control API 2.2, state schema v24 and the single-Mac scope remain unchanged.

## One consolidated repair

[PR #416](https://github.com/hostwright/hostwright/pull/416) adds three targeted
backports to the existing Linux 6.18.55 profile, retaining its four previous
patches and configuration:

- CVE-2026-98813: retain the BPF map's BTF through deferred destructor cleanup.
- CVE-2026-98840: refresh the virtual-console pointer before copy-error exits.
- CVE-2026-98852: use bounded IPv6 header reads and corrected tunnel handling.

The first two are confirmed release blockers in RC.14. The third resolves an
unproven networking clearance case; remote exploitation was not established.
The two [Linux arm64 candidate builds](https://github.com/hostwright/hostwright/actions/runs/39814342881)
produced identical kernel images, configurations and object inventories. The
verified image SHA-256 is `1ea99b8be7e6becdb255bd8dffcd0434f6725cab2514f3386b667d3d8ad4ad91`
(16,216,576 bytes); its embedded configuration matches the existing recipe.
The active shipping pins now select those bytes. This kernel build result does
not qualify the replacement source, signed release artifacts or GA.

RC.14's unapproved staging run was cancelled before build or publication. Its
source, fuzz and partial sanitizer records retain their original bindings. Its
ThreadSanitizer base was interrupted and is not a complete pass. Those records
cannot qualify the replacement source. The [RC.14 snapshot](ga-readiness-2026-10-20-rc14.md)
remains historical.

## Remaining closing sequence

1. Incorporate the verified rebuilt kernel pins, review the complete repair and
   freeze the one replacement candidate. Complete each required qualification
   lane once; do not repeat a passing check without invalidated evidence.
2. Complete provider conformance, ten cycles per provider and the physical-host
   soak (#271), actual backup/recovery/cancellation (#277), the signed VM
   lifecycle (#278), and signed quickstarts/accessibility/website checks (#279).
   Share qualifying runs across issues and close only verified work.
3. After complete RC acceptance, prepare the final `0.0.2` version change,
   qualify its actual bytes, promote them and verify public downloads/vendor-tap
   installation (#281).
4. Audit and submit the cask against those public stable bytes. Keep #282,
   #283 and #284 open until official Homebrew acceptance and fresh-machine
   `brew install hostwright` both pass. Pending external review triggers no
   automatic retesting or scope expansion.

For this October 22 attempt, no new repair round starts after 8 p.m. Eastern.
Stop at 11:59 p.m. Eastern with completed GA or the exact unfinished gates.
A second blocking failure after freezing the replacement ends the attempt.
Required approvals, unavailable credentials or lab capacity, signing failures,
and Homebrew review remain explicit blockers. A date target does not waive a gate.

See the [release process](RELEASE_PROCESS.md) and
[acceptance contract](../reference/release-promotion.md) for the required evidence.
