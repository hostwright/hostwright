#!/bin/bash
set -euo pipefail

if [[ $# != 3 || -z $1 || $1 == '-' || ( $2 != 1 && $2 != 2 ) || $3 != /*.app || -e $3 || -L $3 ]]; then
    printf 'Usage: %s "Apple-issued signing identity" {1|2} /absolute/new-output.app\n' "${0##*/}" >&2
    exit 64
fi

identity=$1
version=$2
output=$3
package=$(cd -- "$(dirname -- "$0")/.." && pwd)
scratch="$package/.build/vm-build-$version"
if [[ $version == 2 ]]; then
    swift build --package-path "$package" --scratch-path "$scratch" -c release \
        --product v314-probe -Xswiftc -DHOSTWRIGHT_V314_BUILD_2
else
    swift build --package-path "$package" --scratch-path "$scratch" -c release --product v314-probe
fi
bin=$(swift build --package-path "$package" --scratch-path "$scratch" -c release --show-bin-path)
stage=$(mktemp -d "${output%/*}/.hostwright-v314-stage.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
bundle="$stage/HostwrightV314Probe.app"
mkdir -p -- "$bundle/Contents/MacOS"
install -m 0755 "$bin/v314-probe" "$bundle/Contents/MacOS/v314-probe"
install -m 0644 "$package/vm/Info.plist" "$bundle/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$bundle/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "1.0.$version" "$bundle/Contents/Info.plist"

# The argument goes only to codesign. The bundle records only the standard signature.
if ! /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp=none "$bundle" 2>/dev/null; then
    printf 'Signing failed. Check that the Apple-issued identity is valid and its key is unlocked.\n' >&2
    exit 1
fi
if ! /usr/bin/codesign -dv --verbose=4 "$bundle" 2>&1 \
    | /usr/bin/grep -E '^Authority=(Developer ID Application:|Apple Development:|Apple Distribution:)' >/dev/null; then
    printf 'Use an Apple-issued Developer ID Application, Apple Development or Apple Distribution identity.\n' >&2
    exit 1
fi
/usr/bin/codesign --verify --strict "$bundle"
mv -- "$bundle" "$output"
printf 'Signed and verified build %s.\n' "$version"
