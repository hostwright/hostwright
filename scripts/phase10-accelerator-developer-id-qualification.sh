#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
service_identifier="dev.hostwright.phase10.accelerator-service"
service_executable="hostwright-accelerator-service"
required_team_identifier="993YC3JY4Q"
temp_parent="${TMPDIR:-/tmp}"
rg_command="$(command -v rg || true)"

if [[ "$temp_parent" != /* || ! -d "$temp_parent" || "$temp_parent" == "/" ]]; then
    printf 'phase10 Developer ID qualification requires a safe absolute temporary parent: %s\n' "$temp_parent" >&2
    exit 70
fi

if [[ "${1:-}" == "--preflight" ]]; then
    [[ -f "$repository_root/Package.swift" ]] || {
        printf 'phase10 Developer ID qualification is missing Package.swift\n' >&2
        exit 66
    }
    [[ -f "$repository_root/Package.resolved" ]] || {
        printf 'phase10 Developer ID qualification is missing Package.resolved\n' >&2
        exit 66
    }
    [[ -d "$repository_root/Sources/HostwrightAccelerator" \
        && -d "$repository_root/Sources/HostwrightAcceleratorXPC" \
        && -d "$repository_root/Sources/HostwrightAcceleratorService" ]] || {
        printf 'phase10 Developer ID qualification is missing accelerator source roots\n' >&2
        exit 66
    }
    for command_name in /usr/bin/swift /usr/bin/xcrun /usr/bin/security /usr/bin/codesign \
        /usr/bin/plutil /usr/bin/jq /usr/bin/shasum /usr/bin/find /bin/cp /bin/date; do
        [[ -x "$command_name" ]] || {
            printf 'phase10 Developer ID qualification command is unavailable: %s\n' "$command_name" >&2
            exit 69
        }
    done
    [[ -n "$rg_command" && -x "$rg_command" ]] || {
        printf 'phase10 Developer ID qualification command is unavailable: rg\n' >&2
        exit 69
    }
    printf 'phase10 Developer ID qualification preflight passed: repository_root=%s\n' "$repository_root"
    exit 0
fi

if [[ "$#" -ne 0 ]]; then
    printf 'usage: %s [--preflight]\n' "$0" >&2
    exit 64
fi

root=""
if ! root="$(mktemp -d "$temp_parent/hostwright-phase10-developer-id.XXXXXX")"; then
    printf 'phase10 Developer ID qualification could not allocate a temporary root under: %s\n' "$temp_parent" >&2
    exit 70
fi

if [[ ! -d "$root" || -L "$root" || "$root" == "/" ]]; then
    printf 'phase10 Developer ID qualification temporary root is unsafe\n' >&2
    /bin/rmdir "$root" 2>/dev/null || true
    exit 70
fi

/bin/chmod 700 "$root"
root_mode="$(/usr/bin/stat -f '%Lp' "$root")"
root_device="$(/usr/bin/stat -f '%d' "$root")"
root_inode="$(/usr/bin/stat -f '%i' "$root")"
root_owner="$(/usr/bin/stat -f '%u' "$root")"

if [[ "$root_mode" != 700 || -z "$root_device" || -z "$root_inode" || -z "$root_owner" ]]; then
    printf 'phase10 Developer ID qualification temporary root identity is invalid\n' >&2
    /bin/rmdir "$root" 2>/dev/null || true
    exit 70
fi

cleanup() {
    local status="$?"
    trap - EXIT

    if [[ -d "$root" && ! -L "$root" \
        && "$(/usr/bin/stat -f '%d' "$root" 2>/dev/null || true)" == "$root_device" \
        && "$(/usr/bin/stat -f '%i' "$root" 2>/dev/null || true)" == "$root_inode" \
        && "$(/usr/bin/stat -f '%u' "$root" 2>/dev/null || true)" == "$root_owner" ]]; then
        while IFS= read -r -d '' path; do
            if [[ -L "$path" || -f "$path" ]]; then
                /bin/unlink "$path"
            elif [[ -d "$path" ]]; then
                /bin/rmdir "$path"
            else
                printf 'phase10 Developer ID cleanup refused unknown path\n' >&2
                status=70
            fi
        done < <(/usr/bin/find "$root" -mindepth 1 -depth -print0)

        if [[ -z "$(/usr/bin/find "$root" -mindepth 1 -print -quit)" ]]; then
            /bin/rmdir "$root"
            printf 'phase10 Developer ID cleanup=verified\n' >&2
        else
            printf 'phase10 Developer ID cleanup refused non-empty root\n' >&2
            status=70
        fi
    else
        printf 'phase10 Developer ID cleanup refused changed root identity\n' >&2
        status=70
    fi

    exit "$status"
}
trap cleanup EXIT

readonly source_manifest="$root/source-manifest.tsv"
readonly source_path_list="$root/source-paths.txt"
readonly binding_input="$root/commit-dirty-binding.txt"
readonly target_info="$root/swift-target-info.json"
readonly build_root="$root/build"
readonly signing_root="$root/signing"
readonly build_log="$root/swift-build.log"
readonly identity_output="$root/codesigning-identities.txt"
readonly signing_log="$root/codesign.log"
readonly bundle="$signing_root/AcceleratorService.xpc"
readonly bundle_contents="$bundle/Contents"
readonly bundle_macos="$bundle_contents/MacOS"
readonly entitlements="$signing_root/accelerator-service.entitlements"
readonly info_plist="$bundle_contents/Info.plist"
readonly raw_receipt="$root/developer-id-qualification.json"

if ! /usr/bin/grep -F 'name: "hostwright-accelerator-service"' "$repository_root/Package.swift" >/dev/null; then
    printf 'phase10 Developer ID qualification refused: product binding is absent\n' >&2
    exit 65
fi

{
    printf '%s\n' 'Package.swift'
    printf '%s\n' 'Package.resolved'
    "$rg_command" --files \
        "$repository_root/Sources/HostwrightAccelerator" \
        "$repository_root/Sources/HostwrightAcceleratorXPC" \
        "$repository_root/Sources/HostwrightAcceleratorService"
} | /usr/bin/sort -u \
    | while IFS= read -r absolute_path; do
        case "$absolute_path" in
            Package.swift|Package.resolved)
                printf '%s\n' "$absolute_path"
                ;;
            "$repository_root"/*)
                printf '%s\n' "${absolute_path#"$repository_root/"}"
                ;;
            *)
                printf 'phase10 Developer ID qualification refused unexpected source path\n' >&2
                exit 65
                ;;
        esac
    done > "$source_path_list"

: > "$source_manifest"
while IFS= read -r relative_path; do
    [[ -n "$relative_path" ]] || continue
    absolute_path="$repository_root/$relative_path"
    [[ -f "$absolute_path" && ! -L "$absolute_path" ]] || {
        printf 'phase10 Developer ID qualification refused missing source input\n' >&2
        exit 66
    }
    digest="$(/usr/bin/shasum -a 256 "$absolute_path" | /usr/bin/awk '{print $1}')"
    byte_count="$(/usr/bin/stat -f '%z' "$absolute_path")"
    printf '%s\t%s\t%s\n' "$relative_path" "$digest" "$byte_count" >> "$source_manifest"
done < "$source_path_list"

source_manifest_sha256="$(/usr/bin/shasum -a 256 "$source_manifest" | /usr/bin/awk '{print $1}')"
commit_id="$(git -C "$repository_root" rev-parse HEAD)"
{
    printf 'commit=%s\n' "$commit_id"
    git -C "$repository_root" status --porcelain=v1 --untracked-files=all
    cat "$source_manifest"
} > "$binding_input"
commit_dirty_digest="$(/usr/bin/shasum -a 256 "$binding_input" | /usr/bin/awk '{print $1}')"
package_resolved_sha256="$(/usr/bin/shasum -a 256 "$repository_root/Package.resolved" | /usr/bin/awk '{print $1}')"
qualification_script_sha256="$(/usr/bin/shasum -a 256 "${BASH_SOURCE[0]}" | /usr/bin/awk '{print $1}')"

toolchain_path="$(/usr/bin/xcrun --find swiftc)"
swift_version="$($toolchain_path --version | /usr/bin/head -n 1)"
developer_dir="$(/usr/bin/xcode-select -p)"
sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
/usr/bin/xcrun --sdk macosx swiftc -print-target-info > "$target_info"
target_triple="$(/usr/bin/jq -r '.target.triple' "$target_info")"

build_root_mode="$(/usr/bin/stat -f '%Lp' "$root")"
[[ "$build_root_mode" == 700 ]] || {
    printf 'phase10 Developer ID qualification refused: output root mode changed\n' >&2
    exit 70
}

build_command=(
    /usr/bin/swift build
    --jobs 1
    --configuration release
    --product "$service_executable"
    --build-path "$build_root"
)
build_command_text=""
printf -v build_command_text '%q ' "${build_command[@]}"
if ! "${build_command[@]}" > "$build_log" 2>&1; then
    /usr/bin/tail -n 40 "$build_log" >&2 || true
    printf 'phase10 Developer ID qualification refused: dedicated release build failed\n' >&2
    exit 65
fi

artifact_candidates=()
while IFS= read -r artifact_path; do
    [[ -n "$artifact_path" ]] && artifact_candidates+=("$artifact_path")
done < <(/usr/bin/find "$build_root" -type f -path "*/release/$service_executable" -print | /usr/bin/sort)

if [[ "${#artifact_candidates[@]}" -ne 1 ]]; then
    printf 'phase10 Developer ID qualification refused: release product artifact is not unique\n' >&2
    exit 65
fi

proven_artifact="${artifact_candidates[0]}"
[[ -f "$proven_artifact" && ! -L "$proven_artifact" ]] || {
    printf 'phase10 Developer ID qualification refused: release product artifact is unsafe\n' >&2
    exit 65
}
/usr/bin/file "$proven_artifact" | /usr/bin/grep -F 'Mach-O 64-bit executable arm64' >/dev/null || {
    printf 'phase10 Developer ID qualification refused: release product is not the expected arm64 executable\n' >&2
    exit 65
}
proven_artifact_sha256="$(/usr/bin/shasum -a 256 "$proven_artifact" | /usr/bin/awk '{print $1}')"

/bin/mkdir -p "$bundle_macos"
/bin/chmod 700 "$signing_root" "$bundle" "$bundle_contents" "$bundle_macos"
/bin/cp "$proven_artifact" "$bundle_macos/$service_executable"
/bin/chmod 700 "$bundle_macos/$service_executable"
copied_artifact_sha256="$(/usr/bin/shasum -a 256 "$bundle_macos/$service_executable" | /usr/bin/awk '{print $1}')"
[[ "$copied_artifact_sha256" == "$proven_artifact_sha256" ]] || {
    printf 'phase10 Developer ID qualification refused: copied artifact digest differs\n' >&2
    exit 65
}

/usr/bin/plutil -create xml1 "$entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$entitlements"
/usr/bin/plutil -create xml1 "$info_plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $service_identifier" "$info_plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $service_executable" "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string XPC!' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.0.2' "$info_plist"

if ! /usr/bin/security find-identity -v -p codesigning > "$identity_output" 2>/dev/null; then
    printf 'phase10 Developer ID qualification refused: signing identity query failed\n' >&2
    exit 65
fi
developer_identity_hashes="$(/usr/bin/awk '/Developer ID Application:/ {print $2}' "$identity_output")"
developer_identity_count="$(printf '%s\n' "$developer_identity_hashes" | /usr/bin/awk 'NF {count++} END {print count + 0}')"
if [[ "$developer_identity_count" != 1 ]]; then
    printf 'phase10 Developer ID qualification refused: expected exactly one Developer ID Application identity\n' >&2
    exit 65
fi
developer_identity_hash="$developer_identity_hashes"
[[ "$developer_identity_hash" =~ ^[A-Fa-f0-9]{40}$ ]] || {
    printf 'phase10 Developer ID qualification refused: identity binding is malformed\n' >&2
    exit 65
}

if ! /usr/bin/codesign --force --sign "$developer_identity_hash" \
    --options runtime --timestamp=none --identifier "$service_identifier" \
    --entitlements "$entitlements" "$bundle_macos/$service_executable" \
    > "$signing_log" 2>&1; then
    printf 'phase10 Developer ID qualification refused: executable signing failed\n' >&2
    exit 65
fi
if ! /usr/bin/codesign --force --sign "$developer_identity_hash" \
    --options runtime --timestamp=none --identifier "$service_identifier" \
    --entitlements "$entitlements" "$bundle" \
    >> "$signing_log" 2>&1; then
    printf 'phase10 Developer ID qualification refused: bundle signing failed\n' >&2
    exit 65
fi

/usr/bin/codesign --verify --strict --deep "$bundle" > /dev/null 2>&1 || {
    printf 'phase10 Developer ID qualification refused: strict deep verification failed\n' >&2
    exit 65
}
/usr/bin/codesign --verify --strict "$bundle_macos/$service_executable" > /dev/null 2>&1 || {
    printf 'phase10 Developer ID qualification refused: strict executable verification failed\n' >&2
    exit 65
}

readonly signing_metadata="$root/signing-metadata.txt"
readonly designated_requirement="$root/designated-requirement.txt"
readonly signed_entitlements="$root/signed-entitlements.plist"
readonly signed_entitlements_json="$root/signed-entitlements.json"
/usr/bin/codesign -d --verbose=4 "$bundle" > "$signing_metadata" 2>&1
/usr/bin/codesign -d -r- "$bundle" > "$designated_requirement" 2>&1
/usr/bin/codesign -d --entitlements :- "$bundle" > "$signed_entitlements" 2>/dev/null
/usr/bin/plutil -convert json -o "$signed_entitlements_json" "$signed_entitlements"

/usr/bin/grep -F "Identifier=$service_identifier" "$signing_metadata" >/dev/null || {
    printf 'phase10 Developer ID qualification refused: bundle identifier check failed\n' >&2
    exit 65
}
/usr/bin/grep -F "TeamIdentifier=$required_team_identifier" "$signing_metadata" >/dev/null || {
    printf 'phase10 Developer ID qualification refused: team binding check failed\n' >&2
    exit 65
}
/usr/bin/grep -F 'Authority=Developer ID Application:' "$signing_metadata" >/dev/null || {
    printf 'phase10 Developer ID qualification refused: Developer ID signature check failed\n' >&2
    exit 65
}
/usr/bin/grep -F 'anchor apple generic' "$designated_requirement" >/dev/null || {
    printf 'phase10 Developer ID qualification refused: designated anchor check failed\n' >&2
    exit 65
}
/usr/bin/grep -F "identifier \"$service_identifier\"" "$designated_requirement" >/dev/null || {
    printf 'phase10 Developer ID qualification refused: designated identifier check failed\n' >&2
    exit 65
}
/usr/bin/grep -F "certificate leaf[subject.OU] = \"$required_team_identifier\"" "$designated_requirement" >/dev/null || {
    printf 'phase10 Developer ID qualification refused: designated team check failed\n' >&2
    exit 65
}
/usr/bin/jq -e \
    'keys == ["com.apple.security.app-sandbox"]
    and .["com.apple.security.app-sandbox"] == true' \
    "$signed_entitlements_json" >/dev/null || {
    printf 'phase10 Developer ID qualification refused: sandbox entitlement check failed\n' >&2
    exit 65
}

signed_executable_sha256="$(/usr/bin/shasum -a 256 "$bundle_macos/$service_executable" | /usr/bin/awk '{print $1}')"
observed_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
/usr/bin/jq -n -S \
    --arg schemaVersion "1" \
    --arg serviceIdentifier "$service_identifier" \
    --arg serviceExecutable "$service_executable" \
    --arg commit "$commit_id" \
    --arg sourceManifestSHA256 "$source_manifest_sha256" \
    --arg commitDirtyDigest "$commit_dirty_digest" \
    --arg packageResolvedSHA256 "$package_resolved_sha256" \
    --arg qualificationScriptSHA256 "$qualification_script_sha256" \
    --arg buildCommand "$build_command_text" \
    --arg isolatedBuildRoot "$build_root" \
    --arg isolatedSigningRoot "$signing_root" \
    --arg targetTriple "$target_triple" \
    --arg toolchainPath "$toolchain_path" \
    --arg swiftVersion "$swift_version" \
    --arg developerDirectory "$developer_dir" \
    --arg sdkPath "$sdk_path" \
    --arg sdkVersion "$sdk_version" \
    --arg provenArtifactSHA256 "$proven_artifact_sha256" \
    --arg copiedArtifactSHA256 "$copied_artifact_sha256" \
    --arg signedExecutableSHA256 "$signed_executable_sha256" \
    --arg observedAt "$observed_at" \
    '{
        schemaVersion: ($schemaVersion | tonumber),
        serviceIdentifier: $serviceIdentifier,
        serviceExecutable: $serviceExecutable,
        commit: $commit,
        sourceManifestSHA256: $sourceManifestSHA256,
        commitDirtyDigest: $commitDirtyDigest,
        packageResolvedSHA256: $packageResolvedSHA256,
        qualificationScriptSHA256: $qualificationScriptSHA256,
        buildCommand: $buildCommand,
        isolatedBuildRoot: $isolatedBuildRoot,
        isolatedSigningRoot: $isolatedSigningRoot,
        targetTriple: $targetTriple,
        toolchainPath: $toolchainPath,
        swiftVersion: $swiftVersion,
        developerDirectory: $developerDirectory,
        sdkPath: $sdkPath,
        sdkVersion: $sdkVersion,
        provenArtifactSHA256: $provenArtifactSHA256,
        copiedArtifactSHA256: $copiedArtifactSHA256,
        signedExecutableSHA256: $signedExecutableSHA256,
        developerIDApplicationSignature: "verified",
        developerIDIdentityCount: 1,
        strictDeepVerification: true,
        designatedIdentifierAndTeam: "verified",
        exactSandboxEntitlements: true,
        notarization: "pending-no-profile",
        metalCorrectnessCell: "passed-inventory-eligibility-only",
        coreMLCorrectnessCell: "pending-no-self-contained-model-fixture",
        mlx: "pending-no-dependency",
        capacityClaim: false,
        guestPassthroughClaim: false,
        observedAt: $observedAt
    }' > "$raw_receipt"

/usr/bin/jq -e \
    '.schemaVersion == 1
    and .serviceIdentifier == "dev.hostwright.phase10.accelerator-service"
    and .developerIDApplicationSignature == "verified"
    and .developerIDIdentityCount == 1
    and .strictDeepVerification == true
    and .designatedIdentifierAndTeam == "verified"
    and .exactSandboxEntitlements == true
    and .notarization == "pending-no-profile"
    and .capacityClaim == false
    and .guestPassthroughClaim == false' \
    "$raw_receipt" >/dev/null

/bin/cat "$raw_receipt"
printf 'phase10 Developer ID application signing and provenance qualification passed; notarization remains pending\n' >&2
