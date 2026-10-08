#!/usr/bin/env python3
"""Render the package cask only after the existing trusted-release verifier passes."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

spec = importlib.util.spec_from_file_location('cask_stage', Path(__file__).with_name('staged-release.py'))
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)

REQUIRED_PAYLOAD = {
    'bin/hostwright', 'bin/hostwright-dist', 'bin/hostwrightd',
    'libexec/hostwright/Hostwright.app/Contents/MacOS/hostwright-desktop',
    'libexec/hostwright/Hostwright.app/Contents/Info.plist',
    'libexec/hostwright/Hostwright.app/Contents/_CodeSignature/CodeResources',
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_manifest(manifest, commit, version, team, allow_prerelease=False):
    require(isinstance(manifest, dict), 'release manifest must be an object')
    require(isinstance(commit, str) and re.fullmatch('[a-f0-9]{40}', commit)
            and commit != '0' * 40, 'exact nonzero source commit required')
    stage.version(version)
    require(version == '0.0.2' or (allow_prerelease and '-rc.' in version),
            'official cask requires stable 0.0.2; --allow-prerelease permits RC qualification only')
    require(re.fullmatch('[A-Z0-9]{10}', team), 'expected Developer ID team required')
    require(manifest.get('schemaVersion') == 3 and manifest.get('sourceDirty') is False,
            'clean schema-3 trusted release required')
    require((manifest.get('sourceCommit'), manifest.get('packageVersion'), manifest.get('releaseTag'))
            == (commit, version, 'v' + version), 'release source/version/tag mismatch')
    require((manifest.get('platform'), manifest.get('architecture'), manifest.get('minimumMacOSMajorVersion'))
            == ('macos', 'arm64', 26), 'cask supports only the declared macOS 26 arm64 package')
    for key in ('applicationSigner', 'installerSigner'):
        require(isinstance(manifest.get(key), dict) and manifest[key].get('teamIdentifier') == team,
                'release signer team mismatch')
    payload = manifest.get('payloadFiles')
    require(isinstance(payload, list) and all(isinstance(item, dict) for item in payload),
            'missing signed payload inventory')
    paths = [item.get('path') for item in payload]
    require(all(isinstance(path, str) for path in paths) and len(paths) == len(set(paths))
            and REQUIRED_PAYLOAD <= set(paths), 'signed native app and managed CLI payload required')
    package = manifest.get('package')
    require(isinstance(package, dict), 'missing package descriptor')
    require(package.get('fileName') == f'hostwright-{version}-macos-arm64-{commit[:12]}.pkg',
            'package filename must bind exact version, architecture and source')
    require(isinstance(package.get('sha256'), str) and re.fullmatch('[a-f0-9]{64}', package['sha256'])
            and package['sha256'] != '0' * 64, 'exact package SHA-256 required')
    require(type(package.get('sizeBytes')) is int and package['sizeBytes'] > 0,
            'positive package byte count required')
    return package


def validate_verification(result, manifest, team):
    require(isinstance(result, dict) and result.get('schemaVersion') == 1
            and result.get('kind') == 'trustedReleaseVerification'
            and result.get('status') == 'passed', 'trusted-release verification did not pass')
    for field in ('sourceCommit', 'packageVersion', 'releaseTag', 'package'):
        require(result.get(field) == manifest[field], 'verifier result does not bind the selected release')
    require(result.get('signerTeamIdentifier') == team, 'verifier signer team mismatch')
    require(type(result.get('verificationCommandCount')) is int and result['verificationCommandCount'] > 0,
            'missing executed trusted verification')
    require(isinstance(result.get('cleanup'), dict) and result['cleanup'].get('status') == 'succeeded',
            'trusted verifier cleanup did not succeed')


def render(manifest):
    version = manifest['packageVersion']
    package = manifest['package']
    # These values have been validated before interpolation into Ruby source.
    return f'''cask "hostwright" do
  version "{version},{manifest['sourceCommit'][:12]}"
  sha256 "{package['sha256']}"

  url "https://github.com/hostwright/hostwright/releases/download/v#{{version.csv.first}}/hostwright-#{{version.csv.first}}-macos-arm64-#{{version.csv.second}}.pkg"
  name "Hostwright"
  desc "Native desktop and command-line control plane for Apple containers"
  homepage "https://hostwright.dev/"

  livecheck do
    url :url
    strategy :github_latest do |json|
      json.fetch("assets", []).filter_map do |asset|
        match = asset["name"]&.match(/\\Ahostwright-(\\d+\\.\\d+\\.\\d+)-macos-arm64-([a-f0-9]{{12}})\\.pkg\\z/i)
        "#{{match[1]}},#{{match[2]}}" if match
      end
    end
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  pkg "hostwright-#{{version.csv.first}}-macos-arm64-#{{version.csv.second}}.pkg"

  uninstall quit:   "dev.hostwright.desktop",
            script: {{
              executable:   "/usr/local/bin/hostwright-dist",
              args:         [
                "package-uninstall", "--prefix", "/usr/local", "--data-policy", "preserve", "--output", "json"
              ],
              sudo:         true,
              must_succeed: true,
            }}

  caveats <<~EOS
    The command-line tools are installed in /usr/local/bin.
    Open the desktop app with:
      open /usr/local/libexec/hostwright/Hostwright.app
    The daemon is not started automatically. Follow the documented identity
    bootstrap and service setup before managing workloads.
    Uninstall preserves workload data and refuses modified or unowned files.
  EOS
end
'''


def generate(release, verifier, commit, version, team, output, allow_prerelease=False):
    require(release.is_absolute() and release.resolve() == release and release.is_dir(),
            'release directory must be an absolute canonical directory')
    require(verifier.is_absolute() and verifier.resolve() == verifier and verifier.is_file()
            and os.access(verifier, os.X_OK), 'explicit canonical trusted verifier executable required')
    require(output.name == 'hostwright.rb' and output.is_absolute()
            and output.parent.resolve() == output.parent and output.parent.is_dir(),
            'output must be hostwright.rb in an existing canonical absolute directory')
    require(not output.is_relative_to(release) and not output.exists() and not output.is_symlink(),
            'output must be new and outside the immutable release directory')
    manifest_path = release / 'release-manifest.json'
    manifest_sha = stage.contained_digest(release, manifest_path.name)
    manifest = stage.load(manifest_path, manifest_sha)
    package = validate_manifest(manifest, commit, version, team, allow_prerelease)
    verifier_sha = stage.digest(verifier)
    command = [str(verifier), 'verify-release', '--release-dir', str(release),
               '--team-id', team, '--format', 'json']
    result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=900)
    def pairs(items):
        values = {}
        for key, value in items:
            require(key not in values, 'duplicate verifier JSON key')
            values[key] = value
        return values
    def nonfinite(_):
        raise ValueError('nonfinite verifier JSON')
    verification = json.loads(result.stdout, object_pairs_hook=pairs, parse_constant=nonfinite)
    validate_verification(verification, manifest, team)
    require(stage.contained_digest(release, manifest_path.name) == manifest_sha
            and stage.digest(verifier) == verifier_sha, 'release manifest or verifier changed during verification')
    package_path = release / package['fileName']
    require(stage.contained_digest(release, package['fileName']) == package['sha256']
            and package_path.stat().st_size == package['sizeBytes'], 'verified package bytes changed')
    text = render(manifest)
    with output.open('x', encoding='utf-8') as handle:
        handle.write(text)
    return dict(kind='hostwright.homebrew-cask-preparation.v1', sourceCommit=commit, version=version,
                output=str(output), caskSHA256=hashlib.sha256(text.encode()).hexdigest(),
                manifestSHA256=manifest_sha, packageSHA256=package['sha256'], verifierSHA256=verifier_sha,
                verification=verification, officialSubmissionEligibleVersion=version == '0.0.2',
                homebrewAccepted=False, installQualified=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release-dir', type=Path, required=True)
    parser.add_argument('--verifier', type=Path, required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--team-id', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--allow-prerelease', action='store_true', help='allow signed RCs for local qualification only')
    args = parser.parse_args()
    print(json.dumps(generate(args.release_dir, args.verifier, args.commit, args.version,
                              args.team_id, args.output, args.allow_prerelease), sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'cask preparation refused: {error}', file=sys.stderr)
        raise SystemExit(1)
