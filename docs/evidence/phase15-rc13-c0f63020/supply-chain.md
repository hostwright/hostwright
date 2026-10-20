# RC.13 supply-chain evidence

Candidate `0.0.2-rc.13` is frozen at `c0f63020f1c4187623d48d9c0770679b8b0de0d1`. This record covers its source and signed distribution artifacts. Installed lifecycle and complete RC/GA acceptance remain separate.

The [derived summary](supply-chain-summary.json) pins individual gate receipts. Full raw logs, source manifests, signature results, scanner output, original failures and independent reviews remain in the retained qualification packet. Exact copies of the small supporting inputs are contained in that packet; the large runtime archives retain their authenticated producer locator and matching signed-stage source binding. This public summary does not replace that packet.

## Signed distribution and source

The [trusted staging run](https://github.com/hostwright/hostwright/actions/runs/39294412896), attempt 2, completed successfully using [runtime producer 39171521610](https://github.com/hostwright/hostwright/actions/runs/39171521610), attempt 1. Native verification checked signing, accepted notarization, Gatekeeper, checksums and CMS signatures. Independent hosted-attestation verification checked seven exact provenance subjects and both exact staged SPDX 2.3 predicates.

| Subject | SHA-256 |
| --- | --- |
| Stage inventory | `381dbf4a23b630a24b2763526cf231c9af164f3ce4600bdc88382b1d70152f5c` |
| Signed ZIP | `673d02b76274f8d75749e1acf312ccb6c2d2e15b17e88af800825c1803decfd8` |
| Signed PKG | `e20cfb87d35587fb47f67a2fde4d77d453dd47510b2567a9fbb12c0e6e131559` |
| Corresponding-source archive | `6fcbc4a5f1dccb187e3bb3d0b22f18299e66dc4b5fa25b7380faa2a5e2ba9a2a` |
| Archive SPDX | `a3a14671b41a5713b07150b26657ebb124ffd9a8d8dcfa8b1e6c1657246d2dc1` |
| Package SPDX | `7ac040eaad10d806e258510c33c2c6398d2921e2bb6fa416c4e294ffb37c2309` |

All nine actual host Mach-O payloads are ARM64; the three inspected guest ELF payloads are AArch64. Both SBOM file maps match the actual 24 payload entries. Independent review joined all 2,543 nonempty host license slices and 325 runtime slices to their reviewed source inventories. The authenticated source closure covers 54 projects and the four kernel patches, with an independently verified upstream kernel signature. Locked-dependency integrity and direct license-policy lanes passed for the exact clean source.

The native verifier initially rejected downloaded sidecars with mode `0600`. A separate projection retained identical file bytes and applied only the documented modes; verification then passed. The original failure remains retained. The outer GitHub transport ZIP digest was reported by metadata rather than independently rehashed; consumed bundle bytes are bound by the authenticated inventory and hosted subject attestations.

## Static security and secret policy

The exact-source [Security workflow](https://github.com/hostwright/hostwright/actions/runs/39171411124) passed. Independent triage records dispositions for 75 scoped CodeQL alerts. Three native-code alerts are scoped to an x86-only implementation; the actual shipped host payloads are ARM64, so that implementation is excluded from this distribution. Private diagnostic details remain in the retained review. This is a scoped disposition, not a claim that every upstream dependency is vulnerability-free.

TruffleHog 3.95.9 scanned all 1,596 tracked candidate source files. All 13 unverified matches were reviewed as non-secrets: invalid-input fixtures, test identifiers, a documented checksum and public OpenPGP material. No credential-validation requests were made.

Shipped text and binary evidence is explicitly bounded. Gitleaks 8.30.1 inspected 39 printable views of 13 authenticated binary inputs: ASCII, UTF-16LE and UTF-16BE views totaling 291,227,557 scanner bytes. These completed without scanner errors or skipped views and produced zero actual findings. Separate synthetic controls produced five findings. Two earlier Aiven matches were reproduced as false positives caused by the pinned TruffleHog UTF-16 decoder combining noncontiguous bytes; neither reported value occurred contiguously in the authenticated binaries.

The built-in source scanner's output-limit failure, TruffleHog's eight binary decoder errors, and Gitleaks's original binary/stdin skips remain preserved and uncredited. The completed source scan, shipped-text scan and printable projections supply distinct evidence for the stated policy. This does not establish absence of obfuscated, encrypted, split or arbitrarily encoded credentials.

## Historical reproducibility variance

The [S372 assessment](../../release/rc2-object-variance-assessment.md) remains historical. Nine release executables matched, but one 105,064-byte `SystemString.swift.o` differed in 16 bytes inside `__LLVM,__swift_modhash`. Its two original objects and failures are retained. All-object reproducibility was not established, and the older result does not qualify RC.13.

## Current-byte vulnerability dispositions

The [policy summary](advisory-policy-summary.json) records 75 explicit dispositions from the retained official advisory set, last captured October 16, together with the exact-source October 18 Go reachable analysis. Independent review bound those dispositions to the actual RC.13 source closure, selected guest source leaves, kernel configuration, seven authenticated runtime payloads and signed distribution identities. It found no unresolved current-byte blocker in that retained set. This is not an October 20 advisory refresh or universal vulnerability clearance.

The two kernel advisory backports (CVE-2026-74747 and CVE-2026-90336), guest NIO fix (GHSA-r3rc-9hpw-54v9), and historical guest inventory mismatch are resolved in the authenticated candidate. Other rows distinguish fixed code, excluded build configuration, different vendor features, and affected code whose required option or consumer is outside the supported path. musl, libarchive, zlib, guest NIOSSL/NIOExtras, Yams and some Go standard-library code retain explicit exceptions; their libraries are not declared universally fixed. Any new encoding, archive option, HTTP/TLS, emitter or resolver consumer requires reassessment. Host NIOSSL 2.37.2 and guest NIOSSL 2.36.0 remain separate components; OS-supplied libraries receive no bundled-version clearance.
