# Homebrew distribution and package names

Current v0.0.2 policy: [ADR 0017](../design/adr-0017-focused-v002-qualification.md).
Signed downloads and the vendor tap are the release channels. Official Homebrew
acceptance and the prior timed qualification campaigns are deferred. Historical
procedures below do not add requirements to the focused five-group policy.


Hostwright's vendor distribution channel is
`brew install hostwright/tap/hostwright`. The published v0.0.2 formula selects
the same verified signed archive as the [release downloads](https://github.com/hostwright/hostwright/releases/tag/v0.0.2).
Check the installed version: historical `0.0.2-dev.12` formulae use older contracts
and are unsupported. Formula publication and public installation are verified
against the release inventory under the [release process](../release/RELEASE_PROCESS.md).

## Installing without a separate tap command

The fully qualified command installs from `hostwright/homebrew-tap` without a
separate `brew tap` command:

```bash
brew install hostwright/tap/hostwright
```

This still uses a third-party tap. Homebrew treats the fully qualified installation
as trust in that specific formula. On current Homebrew, explicit setup for
short-name installation is:

```bash
brew tap hostwright/tap
brew trust --formula hostwright/tap/hostwright
brew install hostwright
```

That setup is local to the user's machine. It does not make Hostwright available
by its short name on a fresh Homebrew installation. See
[tap naming](https://docs.brew.sh/Taps) and
[tap trust](https://docs.brew.sh/Tap-Trust).

## Installing by name on a fresh machine

| Intended command | Distribution requirement |
| --- | --- |
| `brew install hostwright` for the CLI formula | An accepted `hostwright` formula in `Homebrew/homebrew-core` |
| `brew install --cask hostwright` for the application/package | An accepted `hostwright` cask in `Homebrew/homebrew-cask` |
| `brew install hostwright/tap/hostwright` | The existing vendor tap and its verified release formula |

The plain `brew install hostwright` command can also resolve an official cask
when no formula takes precedence; `--cask` explicitly selects the application.
Core inclusion is therefore not the only way to obtain the exact short command.
See Homebrew's [formula/cask name resolution](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/cli/named_args.rb).

The official-repository commands are proposed destinations, not available install
instructions. On October 8, 2026, Homebrew's official formula and cask API endpoints
for `hostwright` both returned 404. Absence is not a name reservation or acceptance.

`Homebrew/hostwright` is not a substitute for either official submission. Tap
coordinates have two components (`owner/tap`); a fully qualified formula has three
(`owner/tap/formula`). Naming a repository `homebrew-hostwright` changes the tap's
coordinates, not the global package name. Keep the product and executable name
`hostwright`; renaming does not remove acceptance requirements.

## Future official submission prerequisites

The current renderer in
[TrustedReleaseSupport.swift](../../Sources/HostwrightDistribution/TrustedReleaseSupport.swift)
installs a signed macOS ZIP with the CLI, helpers, runtime assets and desktop app.
It is not a core source-build formula: [core policy](https://docs.brew.sh/Acceptable-Formulae)
requires source builds or portable platform-independent output and a stable,
immutable upstream release. A core submission needs a separately verified
source-build recipe, pinned dependencies, supported runtime assets and a working
install/test path under Homebrew's build environment. A core formula cannot depend
on a cask.

The signed native app/package makes a cask the more natural official route for the
current full distribution. This is an engineering recommendation, not an
eligibility ruling. Verify the immutable download, checksum, declared platform,
Gatekeeper acceptance, upgrades, uninstall ownership and CLI exposure against real
release bytes. Casks must work on the latest major macOS version; the declared
macOS 26 matrix alone does not establish that requirement at submission time.
See [cask policy](https://docs.brew.sh/Acceptable-Casks).

For source compatibility checks before package installation, the existing
**Qualification tests** workflow accepts an exact merged `source_commit` and
`runner=xcode-27`. GitHub's [runner announcement](https://github.com/actions/runner-images/issues/14404)
records that this preview image uses macOS 27. The workflow verifies the actual
OS/architecture and retains source, image and tool versions with each shard.
Its default remains macOS 26. These hosted source tests do not establish cask
installation, desktop interaction, live VM/provider behavior or Homebrew acceptance;
the signed-package lifecycle checks below remain required.

Both routes require public interest and maintainer review. The
[shared acceptance policy](https://docs.brew.sh/Package-Acceptance-Policy), checked
October 8, 2026, normally requires 30 forks, 30 watchers or 75 stars; for an owner
self-submission, 90 forks, 90 watchers or 225 stars. The repository normally must
be at least 30 days old. Hostwright had 2 stars, 0 forks and 0 watchers at this check.
Exceptions are discretionary; meeting the thresholds does not guarantee acceptance.

## Release order

1. Complete the five focused qualification groups for the final signed bytes.
2. Promote the verified archive/package without rebuilding, verify public downloads,
   then publish the matching vendor formula and verify public installation.
3. Treat official cask/core submission as future work outside v0.0.2. Advertise an
   official short-name command only after its acceptance and fresh-machine verification.

[ADR 0017](../design/adr-0017-focused-v002-qualification.md) supersedes the October 8
official-Homebrew launch requirement. #282 is closed as not planned. This deferral
claims no official acceptance; the release parents depend on signed publication,
focused product qualification and the verified vendor tap.

## Future official cask preparation

The release tooling provides a generator without a hard-coded candidate download
or invented checksum:

```bash
python3 scripts/release/render-homebrew-cask.py \
  --release-dir "$verified_release_directory" \
  --verifier "$trusted_hostwright_dist_executable" \
  --commit "$release_commit" --version 0.0.2 \
  --team-id "$release_team_id" \
  --output "$existing_cask_directory/hostwright.rb"
```

Use absolute canonical paths and an existing output directory. Select the reviewed
`hostwright-dist` executable explicitly: the generator invokes its `verify-release`
command, validates the result and expected signing team, then rechecks manifest,
verifier and package hashes before writing a new file. Existing output is never
overwritten. Release JSON supplied without executed verification is insufficient.
The emitted preparation receipt is not Homebrew acceptance or install evidence.

For RC qualification in a test tap only, use the exact candidate version and add
`--allow-prerelease`. Development releases and app-less legacy packages remain
rejected. Regenerate from stable bytes before official submission; an RC checksum
cannot be reused for GA. The recipe expects that version's immutable package at
its GitHub release URL; generating it does not publish staged private artifacts.
Installation must wait until the protected release flow makes those bytes
available at that URL.

The cask's two-part version retains the product version and twelve-character
source commit. Livecheck obtains both from the stable release's package asset so
future version updates do not retain an old commit in the URL or package name.

Installation uses the existing signed `.pkg` and `/usr/local` lifecycle. The
native app remains at `/usr/local/libexec/hostwright/Hostwright.app`; public command
tools remain in `/usr/local/bin`. Validate both paths on the clean test machine.
The generator does not move manifest-owned files or start the daemon.

The package receipt describes its private installer staging payload; the actual
installation is managed by Hostwright. The cask therefore calls the installed
`hostwright-dist package-uninstall --prefix /usr/local --data-policy preserve
--output json` with elevated authority and requires success. That command verifies
ownership, removes the managed generation and cleans up its exact receipt/staging
payload. Homebrew first requests a graceful quit of the exact desktop bundle
`dev.hostwright.desktop`. A separate broad `pkgutil`, wildcard deletion or user-data
zap would bypass this boundary and is deliberately absent. Homebrew requires an
explicit zap declaration for new casks. The optional `brew uninstall --zap`
operation trashes only `~/Library/Preferences/dev.hostwright.desktop.plist`, the
desktop UI preferences. It does not target manifests, workload state or data.

Homebrew also executes this uninstall stanza during cask upgrades and reinstalls.
Qualify the resulting removal/reinstallation path with a running desktop app and
existing workload data, including restoration after a failed upgrade. Direct
`.pkg` upgrade evidence alone does not establish that this Homebrew path works.
See the [uninstall lifecycle](https://docs.brew.sh/Cask-Cookbook#stanza-uninstall).

Before submission, use an isolated clean macOS environment to run the current
[Homebrew contribution checks](https://docs.brew.sh/Adding-Software-to-Homebrew).
Retain `brew style --cask`, `brew audit --new --cask`, install/launch/upgrade/uninstall
results, exact package/cask digests and proof that unmanaged files and workload data
survive removal. Test an existing vendor-formula installation for name/path
conflicts; do not prescribe `--force` as a migration. Repeat the final short-name
installation after official acceptance with no vendor tap present.

The stable v0.0.2 downloads and vendor-tap checks do not establish official
Homebrew eligibility or current-major-macOS cask qualification. Those prerequisites
must be assessed when a future submission is prepared. A generator test or Ruby/style
pass does not establish official acceptance.
