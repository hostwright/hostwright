# Corresponding-source bundle preparation

`scripts/release/corresponding-source.py prepare` writes a unique directory outside
its checkout. It packages the exact Linux 6.18.15 source archive, verified source
signature/key evidence, the shipped kernel's embedded configuration, all 175 Kata
recipe/config/patch files at commit `660e3bb6535b141c84430acb25b159857278d596`,
original Git executable/symlink modes, all 16 required pinned packaging/static
kernel builder and CI helper files, and the 20 real guest loader source files.
The bundle includes project/dependency licenses, exact source inventories and its
verification scripts. Its canonical manifest binds every file's digest, size, type
and mode, release version, preparation HEAD and source cleanliness/status digest.
The selected publication route is this source bundle alongside signed binaries in
the same GitHub release. It supplies no written offer or blanket legal conclusion.

Preparation verifies pinned input hashes, kernel source archive paths/links, Kata
Git blob hashes, actual configuration hash and guest source hashes before and after
packaging. Verification rejects changed/missing/extra/duplicate entries, unsafe
paths or links, unsupported entry types and wrong source/version/pins. It also
independently re-verifies the kernel source signature using the host reviewed
verifier, never a script extracted from the bundle. Promotion
must obtain the expected archive and manifest digests from authenticated staged
inventory and acceptance evidence; an editable local receipt is not authority.

The trusted release workflow consumes a prepared
`hostwright.corresponding-source.new-runtime.v1` archive through
`--runtime-provenance-archive`. That path verifies the authenticated runtime
provenance and carries the exact archive bytes into staging; the legacy bundle
path remains available for historical source preparation but is refused by
release staging.

The runtime ingredient workflow does not yet produce this archive. The pinned
Apple Containerization 0.35.0 source exists upstream at commit
`44bec8b9933bc491d0cbf44abac90a1f6aaebf6b`, but the current product consumes
prebuilt GHCR vminit and Kata kernel bytes whose deterministic source-to-payload
proof and producer handoff have not been established. Its retained loader and
kernel ingredients therefore cannot satisfy the rebuilt kernel/vminit
source/link/toolchain evidence required by `verify-runtime-provenance.py`. A
release remains blocked until a producer builds the exact shipped inputs, embeds
the source commit and producer run identity, attests the manifest and every
runtime payload, and uploads the exact
`runtime-provenance-${GITHUB_SHA}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}` artifact
containing `runtime-provenance.tar.gz`.

Use `verify-kernel-source-signature.py --inputs <kernel-input-directory> --output
<new-receipt-path>` to independently verify the source's detached signature against
the kernel.org stable signing fingerprint. The script disables key retrieval and
agent autostart and checks cryptographic `VALIDSIG`, not just a `signatureVerified`
JSON field. The public key's expected fingerprint is pinned in reviewed source.

`inspect-vminit-runtime.py` reads the pinned retained OCI layer and recipe's exact
Swift SDK without executing guest binaries or installing SDK components. Its output
records the two actual static stripped AArch64 ELF hashes, build IDs and compiler
comments, and the candidate SDK's 52 target runtime archives, metadata and header
attributions. The downloaded SDK contains no standalone license/notice files.
`ThirdPartyLicenses/runtime-sdk-source-notices` preserves primary upstream runtime
license texts, including Swift/Foundation, Unicode ICU, LLVM runtime, musl and
candidate C libraries; its inventory explicitly records candidate scope.

These outputs remain `prepared-not-release-qualified`. Matching LLVM commit
`b6f042d4515f83404d3f44012144b5e67b2c5791` supports consistency with the SDK but
cannot authenticate a complete OCI source/link inventory. The SDK's curl reports
`8.15.0-DEV`; defaults from a retained upstream recipe do not prove its exact
original build arguments or commits. Final clean frozen-source guest builds,
runtime qualification and authenticated OCI build/link provenance remain required.
