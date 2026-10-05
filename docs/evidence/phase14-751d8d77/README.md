# Phase 14 desktop and signed RC acceptance

Acceptance boundary: [ADR 0015](../../design/adr-0015-reduced-local-release.md), amended by the maintainer on 2026-10-05. This evidence closes the implemented desktop and signed RC packaging scope. It does not complete final v0.0.2 qualification.

The current tested source is `751d8d771bf1e74a01e30b30c22c5f6843d4b70d`, tree `a8a58a5045718f0bb9691bfca1fd479b39e7afa2`, version `0.0.2-rc.2`. The documentation-only closure commits do not replace that artifact source.

| Evidence class | Accepted evidence |
| --- | --- |
| unit-contract | Current signing-run regression, including all 73 selected desktop/distribution contracts and compensation/recovery regressions. |
| local-integration | Successful current repository regression gate and retained physical lifecycle/cleanup observations. |
| live-runtime | Historical ten physical cycles, 40 actions, with original `994cf93c` signed artifact bindings; no current rc.2 device execution claim. |
| distribution-artifact | Authenticated R37265139394/a1 and S37281269383/a1; signed/notarized stage, 33 trust commands and seven authenticated subjects. |
| ux-accessibility | Fifteen historical GUI checks, including menu health, window reopen, keyboard, narrow window and VoiceOver; original source retained. |
| security-assessment | Scoped source review of authenticated desktop/ownership boundaries, current owner-compensation/recovery regressions and signed artifact verification. Full release security qualification remains in Phase 15. |

The original physical source is `994cf93c9e73308a73b5b396134c69407c49b215`, tree `b8ea6ba82d6f0a3cf000504d8e4ef153a6591409`, signing run S37223598413/a1. Thirty-three desktop/authentication source inputs are byte-identical on current751. Their comparison supports reuse under the amended acceptance boundary; it does not turn the historical observations into rc.2 execution. The package owner/compensation files changed in #363 and have current regression coverage.

The remaining five VM routes—upgrade, rollback, re-upgrade, repair and package uninstall—are unqualified and transferred to #278 under Phase 15 #283. The historical four completed logical cases retain their original source and raw failures/recovery outcomes. The #363 fix has not yet been reproduced through the signed VM sequence. These facts still block final release promotion.

Two retained builds have matching hashes for all nine executables. One intermediate `SystemPackage.build/SystemString.swift.o` differs among the 131 object files per build. The successful trusted stage is not a claim of all-object reproducibility. Preserve that diagnostic under #275 before promotion.

Raw producer logs and attestations are retained in the linked [runtime run](https://github.com/hostwright/hostwright/actions/runs/37265139394) and [signing run](https://github.com/hostwright/hostwright/actions/runs/37281269383). Local raw receipt hashes are recorded in the JSON extracts; private user state and GUI captures are not published. `SHA256SUMS` binds the public extracts. No build, test, trust verification or device sequence was rerun to create these extracts.

The current full regression recorded 3,459 XCTest passes, ten disclosed optional skips and zero failures (3,469 cases), plus 61 Swift Testing passes across six suites. All 73 selected desktop/distribution methods passed with zero skips. The raw run contains 439 regression disclosures (438 warning lines and one integration temporary-directory warning); these are retained in the summary and producer log. The ten optional skips do not satisfy required device or promotion gates.
