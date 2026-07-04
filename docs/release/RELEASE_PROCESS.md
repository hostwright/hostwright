# Release Process

Hostwright uses internal phase tags for engineering checkpoints and semantic version tags for public releases.

## Tag Policy

- `phase-*` tags are internal engineering checkpoints only.
- `v*` tags are public release tags only.
- GitHub Releases are created only for `v*` tags.
- Do not create GitHub Releases for `phase-*` tags.
- Do not use `first-release`, `initial-release`, `phase-10-final`, or marketing tags.

## Release Ladder

The approved release ladder is:

1. `v0.1.0-alpha.1`
2. `v0.1.0-alpha.2`
3. `v0.1.0-beta.1`
4. `v0.1.0`
5. `v1.0.0`, only after real users, operational feedback, compatibility stability, and a separate maintainer decision.

## First Public Release

The first public release target is `v0.1.0-alpha.1`.

- GitHub Release title: `Hostwright v0.1.0-alpha.1`
- Release type: pre-release
- Artifact policy: source-only
- Binary attachments: none
- Installer packages: none
- Homebrew formula: none
- Signing/notarization claims: none

This alpha is not production ready.

## Required Gates Before `v0.1.0-alpha.1`

Run and record:

```bash
swift build
swift test list || swift test --list-tests
swift test
scripts/grep-orchard.sh .
scripts/test.sh
```

Review and record:

- GitHub CI passes on the release-hardening pull request.
- `README.md`, CLI docs, install docs, compatibility docs, limitations, release notes, and security/safety notes agree.
- No public docs claim production readiness.
- No docs claim binaries, installers, Homebrew, signing, or notarization.
- No docs claim Kubernetes, CRI, Docker API, Compose parity, tunnels, cloud, DNS, GPU/ANE, daemon loop, broad lifecycle, image cleanup, or volume cleanup support.
- `git ls-files` contains no `.DS_Store`, `.build`, `site/`, `.env`, keys, local source archives outside preserved paths, or other local-only files.

## Tag And Release Steps

Only after the Phase 10 branch is merged to `main` and final verification passes:

```bash
git checkout main
git pull --ff-only
git tag -a v0.1.0-alpha.1 -m "Hostwright v0.1.0-alpha.1"
git push origin v0.1.0-alpha.1
```

Then create a GitHub pre-release for `v0.1.0-alpha.1` named `Hostwright v0.1.0-alpha.1` using `docs/release/v0.1.0-alpha.1-notes.md` as the body.

