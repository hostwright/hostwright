#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_file="$repository_root/scripts/phase10-metal-command-buffer-cell.swift"
temp_parent="${TMPDIR:-/tmp}"

if [[ "$temp_parent" != /* || ! -d "$temp_parent" || "$temp_parent" == "/" ]]; then
    printf 'phase10 Metal cell requires a safe absolute temporary parent: %s\n' "$temp_parent" >&2
    exit 70
fi

if [[ "${1:-}" == "--preflight" ]]; then
    [[ -f "$source_file" ]] || {
        printf 'phase10 Metal cell source is missing: %s\n' "$source_file" >&2
        exit 66
    }
    for command_name in /usr/bin/xcrun /usr/bin/jq /usr/bin/shasum /bin/date; do
        [[ -x "$command_name" ]] || {
            printf 'phase10 Metal cell command is unavailable: %s\n' "$command_name" >&2
            exit 69
        }
    done
    printf 'phase10 Metal cell preflight passed: repository_root=%s\n' "$repository_root"
    exit 0
fi

if [[ "$#" -ne 0 ]]; then
    printf 'usage: %s [--preflight]\n' "$0" >&2
    exit 64
fi

root=""
if ! root="$(mktemp -d "$temp_parent/hostwright-phase10-metal.XXXXXX")"; then
    printf 'phase10 Metal cell could not allocate a temporary root under: %s\n' "$temp_parent" >&2
    exit 70
fi

if [[ ! -d "$root" || -L "$root" || "$root" == "/" ]]; then
    printf 'phase10 Metal cell temporary root is unsafe: %s\n' "$root" >&2
    /bin/rmdir "$root" 2>/dev/null || true
    exit 70
fi

/bin/chmod 700 "$root"
root_mode="$(stat -f '%Lp' "$root")"
root_device="$(stat -f '%d' "$root")"
root_inode="$(stat -f '%i' "$root")"
root_owner="$(stat -f '%u' "$root")"

if [[ "$root_mode" != 700 || -z "$root_device" || -z "$root_inode" || -z "$root_owner" ]]; then
    printf 'phase10 Metal cell temporary root identity is invalid: %s\n' "$root" >&2
    /bin/rmdir "$root" 2>/dev/null || true
    exit 70
fi

cleanup() {
    local status="$?"
    trap - EXIT

    if [[ -d "$root" && ! -L "$root" \
        && "$(stat -f '%d' "$root" 2>/dev/null || true)" == "$root_device" \
        && "$(stat -f '%i' "$root" 2>/dev/null || true)" == "$root_inode" \
        && "$(stat -f '%u' "$root" 2>/dev/null || true)" == "$root_owner" ]]; then
        while IFS= read -r -d '' path; do
            if [[ -L "$path" || -f "$path" ]]; then
                /bin/unlink "$path"
            elif [[ -d "$path" ]]; then
                /bin/rmdir "$path"
            else
                printf 'phase10 Metal cell cleanup refused unknown path: %s\n' "$path" >&2
                status=70
            fi
        done < <(/usr/bin/find "$root" -mindepth 1 -depth -print0)

        if [[ -z "$(/usr/bin/find "$root" -mindepth 1 -print -quit)" ]]; then
            /bin/rmdir "$root"
            printf 'phase10 Metal cell cleanup=verified\n' >&2
        else
            printf 'phase10 Metal cell cleanup refused non-empty root: %s\n' "$root" >&2
            status=70
        fi
    else
        printf 'phase10 Metal cell cleanup refused changed root identity: %s\n' "$root" >&2
        status=70
    fi

    exit "$status"
}
trap cleanup EXIT

readonly raw_receipt="$root/metal-cell.json"
readonly binary="$root/metal-cell"
/usr/bin/xcrun --sdk macosx swiftc -O \
    -framework Foundation \
    -framework Metal \
    "$source_file" \
    -o "$binary"

"$binary" "$raw_receipt"
source_sha256="$(/usr/bin/shasum -a 256 "$source_file" | /usr/bin/awk '{print $1}')"
observed_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"

/usr/bin/jq -e \
    '.schemaVersion == 1
    and .mode == "metal"
    and .framework == "Metal"
    and .status == "passed"
    and .evidenceSource == "host-native-execution-self-test"
    and .commandBufferStatus == "completed"
    and .resultValidation == "exact-output-match"
    and .deviceAvailable == true
    and .capacityClaim == false
    and .quotaClaim == false
    and .reservationClaim == false
    and .guestPassthroughClaim == false
    and .input == [1, 3, 5, 7]
    and .expected == [2, 4, 6, 8]
    and .observed == [2, 4, 6, 8]' \
    "$raw_receipt" >/dev/null

/usr/bin/jq -S \
    --arg sourceSHA256 "$source_sha256" \
    --arg observedAt "$observed_at" \
    '. + {
        sourceSHA256: $sourceSHA256,
        observedAt: $observedAt,
        cleanupScope: "private-temporary-root"
    }' \
    "$raw_receipt"

printf 'phase10 Metal correctness cell passed: command-buffer/kernel result exact; no capacity claim\n' >&2
