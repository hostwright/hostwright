# Staged v0.0.2 release promotion

The protected manual `trusted-release.yml` workflow stages `0.0.2-dev.1` through
`dev.999`, `0.0.2-rc.1` through `rc.99`, and stable `0.0.2`. Source must be an exact
clean commit already merged to main. Existing historical tags remain immutable.
The existing distribution builder performs two isolated clean builds, signing,
notarization, stapling and independent verification. Staging has no repository
write authority and creates no public tag or release.

`stage-inventory.json` binds the full ZIP, package, CMS, SBOM, evidence and formula
inventory to source, version, stage run and attempt. Its GitHub-hosted attestation
is verified against the exact trusted workflow path and workflow source digest.

`release-qualification-acceptance.yml` uses the existing protected `release`
environment and its recorded release authority. Acceptance and promotion require
its configured reviewers and deployment restriction to main; they preserve the
existing self review policy. Dispatch also requires main. The independent review
is an agent review, not an authenticated GitHub reviewer or external human review.
Dispatch pins its retained report SHA-256. The aggregate records its issuer claim,
review kind and report digest separately from the authenticated acceptance actor.
The protected workflow authenticates acceptance of those exact evidence bytes
through its attestation. A local JSON `status: passed` supplies no publication
authority.
Prepare a redacted evidence export outside the source checkout. Its
`evidence-inventory.json` contains `kind: hostwright.qualification-export.v1`,
the exact `sourceCommit` and `version`, and a `files` map from every gate receipt
and raw attachment's relative path to its SHA-256. Place the complete directory
at `/Volumes/T9/hostwright/v002/qualification-export/<inventory-sha256>`.
The protected `retain-qualification-evidence.yml` dispatch takes that digest,
source and version. It verifies the complete inventory before copying, rechecks
copied bytes, rejects symlinks and unlisted files, and retains the export for
90 days. Use a task-owned ephemeral runner for this one job; it does not publish
a release or determine that qualification passed.

The acceptance dispatch downloads the exact stage run and an exact successful
`retain-qualification-evidence.yml` main run's
`hostwright-final-qualification-evidence` artifact. Each named gate JSON requires
exact `sourceCommit`, final `version`, `status`, clean source before/after, and an
`attachments` map of safe relative raw-evidence paths to SHA-256 digests. Required
gates are source regression, documentation contracts, final signed/notarized
artifacts, VM installation lifecycle, both full sanitizer suites, all six parser
fuzz targets, dependencies/security, secrets, licenses/SBOM, independent review,
desktop/accessibility, Compose execution, Apple container 1.0.0 and 1.1.0/Containerization SDK 0.35.0
provider conformance and ten cycles each, and the 30-minute single-host soak.
See `scripts/release/accept-qualification.py` for exact gate keys and lane fields.
Every provider, soak, VM, desktop, Compose, dependency/content and independent
review artifact gate binds the exact staged `inventorySHA256`. Independent review
also identifies `reviewKind: independent-agent`, `reviewer` and `reportSHA256`,
and retains the matching report in its attachments. VM lifecycle records all ten `passedOperations` (archive and package install, reboot, both baseline upgrades, interrupted upgrade, downgrade refusal, authorized rollback, repair, uninstall).
Provider receipts record `conformancePassed` and `completedCycles`; soak records
`elapsedSeconds`; sanitizer receipts record `fullSuiteLanes`; fuzz records each
of the six `targets` with actual `elapsedSeconds` and `status`.

Acceptance retains all reviewed raw evidence and produces an OIDC-attested
aggregate with every gate receipt hash. `promote-release.yml` verifies the exact
successful stage and acceptance runs, exact trusted signer paths and source
digests, aggregate run identity, inventory, source, version and independent review.
It downloads staged bytes and performs no rebuild. RC qualification cannot promote
GA because every gate and the signed manifest bind the exact final version.
It publishes stable as a release and dev/RC as prereleases, compares every public
asset with its staged original, and compensates only a tag and release carrying
its own exact source and unpredictable ownership marker.

Sanitizer and fuzz wrappers retain absolute stable build caches outside the clean
checkout. Checkpoint resume requires identical source, toolchain, command, duration,
logs and retained corpus bytes. Fuzz requires at least 300 actual seconds for all
six targets, preserves initial/final corpora, replays both, and retains coverage
statistics and crash artifacts. Failed logs/checkpoints remain for investigation;
use a new evidence directory for a fresh lane after fixing a failure. Run only one
heavy Swift process on the physical lab host.

Schema 3 adds verified transitive notices and runtime license/source inventories.
Trusted release preflight requires verified corresponding source and runtime
provenance. See [third-party distribution inventory](third-party-distribution.md).
