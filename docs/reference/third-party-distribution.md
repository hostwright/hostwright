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

The separate runtime inventory records the rebuilt Linux kernel and guest OCI asset
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

## Runtime producer and signing handoff

The runtime producer rebuilds the Linux kernel, guest binaries and Go loader twice
and requires matching payload bytes. It installs the authenticated Swift SDK under
the build directory to keep the SDK path independent of the user's home directory. The
signed Linux source archive, applied
patches, actual configuration, compiler/linker inputs, selected source files,
complete source inventories and license texts form the corresponding-source
closure. The guest OCI layout contains a direct image manifest. Its descriptor,
configuration and layer are locked to rebuilt bytes; it is not the previously
published GHCR image.

Dispatch `runtime-ingredients.yml` on the reviewed `main` commit. A successful
loader-only push run is insufficient. The manual run must complete SDK evidence
selection, native runtime, loader and final provenance jobs. The SDK may come from
a new compilation or an authenticated retained producer. The final artifact is
`runtime-provenance-<source SHA>-<run ID>-<attempt>` and contains exactly
`runtime-provenance.tar.gz`. The manifest and every runtime payload receive GitHub
attestations from that workflow. Rerun failed jobs to reuse successful upstream
artifacts. Consumers use each upstream job's original artifact name and authenticate
its original run attempt; the final handoff is attested by the assembling attempt.

The SDK compiler job retains an authenticated
`runtime-swift-sdk-checkpoint-<source SHA>-<run ID>-<attempt>` for seven days before
source mapping begins. It contains compiled SDK bytes, raw object/archive inputs,
source checkouts, compiler traces, build metadata and referenced temporary sources.
Host executables outside the SDK are omitted with recorded hashes. Evidence
collection restores these inputs in a separate job and never runs the SDK compiler.
A checkpoint is not qualified runtime evidence until source verification passes.

After merging an evidence-only fix, dispatch the workflow on `main` with both
`sdk_checkpoint_run` and `sdk_checkpoint_attempt` set to the original SDK producer.
The resolver prefers a complete `runtime-swift-sdk` artifact from that exact
attempt, falling back to its raw build checkpoint. The consumer authenticates the
original source SHA, workflow, run, attempt and archive hashes, requires that source
to be an ancestor of the current commit, and compares source pins, patches,
materialization, compiler configuration and build steps. Changed compilation inputs
refuse reuse. Retained inventories must match those source pins; selected runtime
objects still require complete source evidence. An uploaded SDK alone does not
establish source qualification. Recovery writes new evidence without replacing the
original authenticated files. The native runtime still rebuilds twice from the
current source.
Leave both inputs empty when a new SDK compilation is required. Checkpoints use
artifact storage, so retain/download them deliberately before their expiry.

The signing consumer verifies the exact source commit, repository, main ref,
workflow, run, attempt and payload digests. A valid attestation from another run or
attempt cannot satisfy the requested handoff. Materialize the retained archive with:

```bash
python3 scripts/release/materialize-runtime-assets.py \
  --archive "$ARCHIVE" --output "$ASSETS" --source-commit "$SOURCE_SHA" \
  --run-id "$RUNTIME_RUN_ID" --attempt "$RUNTIME_ATTEMPT"
```

Local prepared evidence is useful for reviewing pins and source coverage. It does
not replace the authenticated producer run for the final merged commit. Source
qualification also does not establish Developer ID signing, notarization,
Gatekeeper acceptance, physical-Mac desktop behavior or package lifecycle results.
Phase 14 requires those independent checks before its final evidence closures;
publication remains Phase 15 work.

## Verification and refresh

Run `python3 scripts/release/validate-third-party-notices.py --root "$PWD"` for the
light source pin/text check. Add `--require-qualified` for release acceptance; it refuses blocked assets or
missing corresponding-source evidence.

The producer also compares the freshly verified runtime inventory and public
notices with the committed qualified files. To prepare a reviewed runtime refresh,
use a complete prepared proof and a clean checkout at that proof's exact source
commit:

```bash
python3 scripts/release/qualify-runtime-inventory.py \
  --prepared-root "$PREPARED_RUNTIME" --source-root "$CLEAN_SOURCE" \
  --output "$NEW_INVENTORY_OUTPUT"
```

The output directory must be new and absolute. Review its inventories, notices,
and kernel configuration together with the actual runtime digest and size updates
before committing. This local verification does not authenticate a workflow run.

Regenerate from read-only, exact-revision SwiftPM checkouts and Go caches with
`scripts/release/collect-third-party-notices.py`. Its required arguments are
`--root`, `--checkouts`, `--go-modules` and `--go-toolchain`; `--verify` compares
reviewed files without writing them. Keep upstream BoringSSL and kernel license
files under `ThirdPartyLicenses/upstream` at their recorded versions. Review any
pin, document, checksum or runtime qualification change before a new release.
