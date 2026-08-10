#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
service_identifier="dev.hostwright.phase10.accelerator-service"
service_executable="hostwright-accelerator-service"
temp_parent="${TMPDIR:-/tmp}"

if [[ "$temp_parent" != /* || ! -d "$temp_parent" || "$temp_parent" == "/" ]]; then
    printf 'phase10 accelerator TMPDIR must be an existing absolute non-root directory: %s\n' \
        "$temp_parent" >&2
    exit 70
fi

if ! root="$(mktemp -d "$temp_parent/hostwright-phase10-accelerator.XXXXXX")"; then
    printf 'phase10 accelerator could not allocate a private qualification root\n' >&2
    exit 70
fi
if [[ ! -d "$root" || -L "$root" || "$root" == "/" ]]; then
    printf 'phase10 accelerator qualification root is unsafe: %s\n' "$root" >&2
    /bin/rmdir "$root" 2>/dev/null || true
    exit 70
fi

if ! root_mode="$(stat -f '%Lp' "$root")" \
    || ! root_device="$(stat -f '%d' "$root")" \
    || ! root_inode="$(stat -f '%i' "$root")" \
    || ! root_owner="$(stat -f '%u' "$root")"; then
    printf 'phase10 accelerator could not capture qualification-root identity\n' >&2
    /bin/rmdir "$root" 2>/dev/null || true
    exit 70
fi
if [[ "$root_mode" != 700 || "$root_device" == "" || "$root_inode" == "" || "$root_owner" == "" ]]; then
    printf 'phase10 accelerator qualification root identity is invalid: %s\n' "$root" >&2
    /bin/rmdir "$root" 2>/dev/null || true
    exit 70
fi

readonly repository_root service_identifier service_executable temp_parent root
readonly bundle="$root/AcceleratorService.xpc"
readonly build_root="$root/swift-build"
readonly entitlements="$root/accelerator-service.entitlements"
readonly report="$root/qualification.json"
readonly root_mode root_device root_inode root_owner

cleanup() {
    local status="$?"
    trap - EXIT
    if [[ -d "$root" && ! -L "$root" \
        && "$(stat -f '%d' "$root" 2>/dev/null || true)" == "$root_device" \
        && "$(stat -f '%i' "$root" 2>/dev/null || true)" == "$root_inode" \
        && "$(stat -f '%u' "$root" 2>/dev/null || true)" == "$root_owner" ]]; then
        local path
        while IFS= read -r -d '' path; do
            if [[ -L "$path" || -f "$path" ]]; then
                /bin/unlink "$path"
            elif [[ -d "$path" ]]; then
                /bin/rmdir "$path"
            else
                printf 'phase10 accelerator cleanup refused unknown path: %s\n' "$path" >&2
                status=70
            fi
        done < <(/usr/bin/find "$root" -mindepth 1 -depth -print0)
        if [[ -z "$(/usr/bin/find "$root" -mindepth 1 -print -quit)" ]]; then
            /bin/rmdir "$root"
        else
            printf 'phase10 accelerator cleanup refused non-empty root: %s\n' "$root" >&2
            status=70
        fi
    else
        printf 'phase10 accelerator cleanup refused changed root identity: %s\n' "$root" >&2
        status=70
    fi
    exit "$status"
}
trap cleanup EXIT

if [[ "${1:-}" == "--preflight" ]]; then
    [[ -d "$repository_root/Sources/HostwrightAcceleratorService" ]] || {
        printf 'phase10 accelerator service source directory is missing under %s\n' \
            "$repository_root" >&2
        exit 70
    }
    printf 'phase10 accelerator qualification preflight passed: repository_root=%s\n' \
        "$repository_root"
    exit 0
fi

[[ "$(stat -f '%Lp' "$root")" == 700 ]] || {
    printf 'phase10 accelerator root is not private\n' >&2
    exit 70
}

command -v swift >/dev/null
command -v codesign >/dev/null
command -v plutil >/dev/null
command -v jq >/dev/null

cd "$repository_root"
swift build --configuration release --product "$service_executable" --build-path "$build_root"
readonly built_service="$(swift build --show-bin-path --configuration release --build-path "$build_root")/$service_executable"
[[ -x "$built_service" && ! -L "$built_service" ]] || {
    printf 'phase10 accelerator service product is missing or unsafe\n' >&2
    exit 70
}

/bin/mkdir -p "$bundle/Contents/MacOS"
/bin/chmod 700 "$bundle" "$bundle/Contents" "$bundle/Contents/MacOS"
/bin/cp "$built_service" "$bundle/Contents/MacOS/$service_executable"
/bin/chmod 700 "$bundle/Contents/MacOS/$service_executable"

/usr/bin/plutil -create xml1 "$entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$entitlements"

/usr/bin/plutil -create xml1 "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $service_identifier" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $service_executable" "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string XPC!' "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.0.2' "$bundle/Contents/Info.plist"

/usr/bin/codesign --force --sign - --identifier "$service_identifier" \
    --entitlements "$entitlements" "$bundle/Contents/MacOS/$service_executable"
/usr/bin/codesign --force --sign - --identifier "$service_identifier" \
    --entitlements "$entitlements" "$bundle"
/usr/bin/codesign --verify --strict --verbose=2 --deep "$bundle"

readonly signing_metadata="$(/usr/bin/codesign -d --verbose=4 "$bundle" 2>&1 || true)"
printf '%s\n' "$signing_metadata" | /usr/bin/grep -F "Identifier=$service_identifier" >/dev/null
printf '%s\n' "$signing_metadata" | /usr/bin/grep -F 'Signature=adhoc' >/dev/null

readonly signed_entitlements="$(/usr/bin/codesign -d --entitlements :- "$bundle" 2>/dev/null \
    | /usr/bin/plutil -convert json -o - -)"
printf '%s' "$signed_entitlements" \
    | /usr/bin/jq -e 'keys == ["com.apple.security.app-sandbox"] and .["com.apple.security.app-sandbox"] == true' \
    >/dev/null

readonly designated_requirement="$(/usr/bin/codesign -d -r- "$bundle" 2>&1 || true)"
if ! printf '%s\n' "$designated_requirement" \
    | /usr/bin/grep -F "identifier \"$service_identifier\"" >/dev/null; then
    printf '%s\n' "$designated_requirement" \
        | /usr/bin/grep -F '# designated => cdhash ' >/dev/null || {
        printf 'phase10 accelerator designated requirement is not identity-bound: %s\n' \
            "$service_identifier" >&2
        exit 70
    }
fi

/usr/bin/jq -n \
    --arg identifier "$service_identifier" \
    --arg bundle "$bundle" \
    --arg signing "adhoc" \
    --arg requirement "transport requirement remains: anchor apple generic, team 993YC3JY4Q, identifier $service_identifier, app-sandbox=true" \
    '{
        kind: "hostwright.phase10.accelerator-xpc.local-signing.v1",
        serviceIdentifier: $identifier,
        bundlePath: $bundle,
        signature: $signing,
        strictSignatureVerified: true,
        sandboxEntitlementsExact: true,
        designatedRequirementChecked: true,
        transportRequirement: $requirement,
        developerID: "pending",
        notarization: "pending",
        hostNativeHardwareExecution: "pending"
    }' > "$report"
/bin/chmod 600 "$report"
/usr/bin/jq -e --arg identifier "$service_identifier" \
    '.kind == "hostwright.phase10.accelerator-xpc.local-signing.v1"
     and .serviceIdentifier == $identifier
     and .strictSignatureVerified == true
     and .sandboxEntitlementsExact == true
     and .developerID == "pending"
     and .notarization == "pending"
     and .hostNativeHardwareExecution == "pending"' "$report" >/dev/null

printf '%s\n' "phase10 accelerator local service/signing qualification passed; Developer ID, notarization, and hardware execution remain pending"
