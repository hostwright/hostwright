# Third-party distribution inventory

New distribution schema 3 ships `THIRD_PARTY_NOTICES`,
`third-party-license-inventory.json`, and `runtime-license-inventory.json` under
`share/doc/hostwright`. Both ZIP/archive and installer verification check these
files, their text ranges and hashes, exact dependency pins, and the complete actual
runtime asset file inventory. Trusted verification additionally compares the host
license pins with the CMS-authenticated build provenance. Homebrew installs all
three documents. Existing schema 1 and 2 layouts and their historical SPDX remain
verifiable.

The host inventory covers all 31 exact `Package.resolved` revisions, root LICENSE
and NOTICE files, nested license documents, and preserved C/assembly attribution
headers. The BoringSSL copies in Swift Crypto and NIO SSL have different upstream
revisions; their original full license files are retained at those exact revisions.
Root package expressions describe the root project's licensing only. They do not
relicense embedded components or establish which symbols enter a particular binary.

The separate runtime inventory records the pinned Kata kernel and Apple OCI asset
contract, all 27 pins from the guest `vminitd/Package.resolved`, the guest loader's
seven Go module versions/checksums, and the hashes of its `go.mod` and `go.sum`.
All 27 guest root/nested license and notice texts are retained at their exact
revisions, including the separate original BoringSSL revisions. Retained loader
build metadata binds all 20 source file hashes, six actually linked modules and
Linux arm64 CGO-disabled build settings. The seventh module is source/test-only.
Pinned upstream kernel and image recipes are preserved with source URLs/hashes;
these are recipe evidence rather than proof of exact binary provenance.
Go module licenses and notices are preserved from caches matched to the exact
`go.sum` entries. The Go 1.26.5 license, patents notice and bundled standard-library
vendor licenses are retained. Assembly adds exact hashes, sizes and modes of every
actual supplied runtime file, including the guest loader; a contract pin and an
observed payload digest remain distinct evidence.

Schema 3 SPDX declares the Hostwright project's Apache-2.0 license, concludes the
known kernel file as GPL-2.0-only, and leaves other artifact-content conclusions as
`NOASSERTION`. The actual dependency/license-text inventories supply attribution.
An artifact-content SPDX file is not proof that distribution requirements passed.
Trusted release preflight and independent verification refuse incomplete runtime
source/license qualification.

## Current blocking evidence

- **Kata kernel:** the shipped `vmlinux-6.18.15-186` is pinned to the Kata 3.28.0
  archive and exact kernel digest. The corresponding kernel source, applied
  source archive is retained with primary checksum verification; the actual
  embedded arm64 configuration and GCC 11.4.0/Binutils 2.38 banner are recorded.
  Applied patches and compilation/installation scripts still need to be packaged
  with that exact source/config and audited against the shipped bytes. Full build
  flags are unproven. The approved route is a corresponding-source bundle alongside
  binaries in the same GitHub release; this bundle is not yet staged/verified.
  Kata documents how its build script applies patches and configuration and how
  the suffix identifies configuration revision. See the pinned
  [kernel build guide](https://github.com/kata-containers/kata-containers/blob/3.28.0/tools/packaging/kernel/README.md).
  GPLv2's executable-distribution conditions cover corresponding source and
  compilation/installation scripts; generic upstream links do not by themselves
  establish the chosen route. See the [GNU GPLv2 FAQ](https://www.gnu.org/licenses/old-licenses/gpl-2.0-faq.en.html).
  This route supplies source alongside the binaries and creates no written offer.
- **Apple vminit OCI:** its guest lockfile has 27 pins, including revisions that
  differ from the host graph. The exact OCI digest-to-source/build provenance and
  guest component licenses must be qualified independently. The pinned
  [guest Makefile](https://github.com/apple/containerization/blob/44bec8b9933bc491d0cbf44abac90a1f6aaebf6b/vminitd/Makefile)
  selects the Swift 6.3 static Linux musl SDK; the
  [image recipe](https://github.com/apple/containerization/blob/44bec8b9933bc491d0cbf44abac90a1f6aaebf6b/Makefile)
  constructs the root filesystem from guest binaries. Those recipes do not alone
  establish the linked runtime contents or licensing of the selected published OCI
  layer. Guest dependency texts at their actual older revisions are retained; the actual
  static Swift/musl SDK component inventory remains incomplete.
- **Guest loader:** actual source is under `Guest/HostwrightNetfilter`, with an
  existing historical receipt for source `5216c716ff16c8e93bc9e461af3fd95f26ce569b`
  and two identical Go 1.26.5 ELF builds. That receipt is
  `prepared-not-runtime-qualified`. Final frozen-source clean build/qualification,
  and runtime qualification remain required. Actual linked-module and build-setting
  evidence from both retained binaries is now recorded.
  Preserved module/cache license documents close the attribution-text collection
  gap, not these final binary evidence gaps.

`runtime-license-inventory.json` therefore remains `blocked`. Do not interpret this
packet as a legal compliance conclusion or authorization to publish. Closing the
remaining gaps requires actual reviewed source/build/distribution evidence.

## Verification and refresh

Run `python3 scripts/release/validate-third-party-notices.py --root "$PWD"` for the
light source pin/text check. Add `--require-qualified` only for release acceptance;
it currently refuses the unresolved runtime inventory.

Regenerate from read-only, exact-revision SwiftPM checkouts and Go caches with
`scripts/release/collect-third-party-notices.py`. Its required arguments are
`--root`, `--checkouts`, `--go-modules` and `--go-toolchain`; `--verify` compares
reviewed files without writing them. Keep upstream BoringSSL and kernel license
files under `ThirdPartyLicenses/upstream` at their recorded versions. Review any
pin, document, checksum or runtime qualification change before a new release.
