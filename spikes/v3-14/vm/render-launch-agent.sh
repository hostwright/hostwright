#!/bin/bash
set -euo pipefail

usage() {
    printf 'Usage: %s /absolute/installed.app listener-ip listener-port /absolute/existing-log-directory [/absolute/quic-public-certificate.der]\n' "${0##*/}" >&2
    exit 64
}

if [[ $# != 4 && $# != 5 ]] || [[ $1 != /*.app || ! -x $1/Contents/MacOS/v314-probe || $4 != /* || ! -d $4 ]]; then
    usage
fi
arguments=("$1/Contents/MacOS/v314-probe" dial "$2" "$3")
if [[ $# == 5 ]]; then
    if [[ $5 != /* || ! -f $5 || ! -r $5 ]]; then
        usage
    fi
    arguments[1]=quic-dial
    arguments+=("$5")
fi

template=$(cd -- "$(dirname -- "$0")" && pwd)/dev.hostwright.spike.local-network.plist
plist=$(/usr/bin/plutil -replace ProgramArguments -array -o - "$template")
for argument in "${arguments[@]}"; do
    plist=$(/usr/bin/plutil -insert ProgramArguments -string "$argument" -append -o - - <<< "$plist")
done

/usr/bin/plutil -replace StandardOutPath -string "$4/probe.log" -o - - <<< "$plist" \
    | /usr/bin/plutil -replace StandardErrorPath -string "$4/probe.error.log" -o - -
