#!/bin/bash
set -euo pipefail

if [[ $# != 4 || $1 != /*.app || ! -x $1/Contents/MacOS/v314-probe || $4 != /* || ! -d $4 ]]; then
    printf 'Usage: %s /absolute/installed.app listener-ip listener-port /absolute/existing-log-directory\n' "${0##*/}" >&2
    exit 64
fi
template=$(cd -- "$(dirname -- "$0")" && pwd)/dev.hostwright.spike.local-network.plist
/usr/bin/plutil -replace ProgramArguments.0 -string "$1/Contents/MacOS/v314-probe" -o - "$template" \
    | /usr/bin/plutil -replace ProgramArguments.2 -string "$2" -o - - \
    | /usr/bin/plutil -replace ProgramArguments.3 -string "$3" -o - - \
    | /usr/bin/plutil -replace StandardOutPath -string "$4/probe.log" -o - - \
    | /usr/bin/plutil -replace StandardErrorPath -string "$4/probe.error.log" -o - -
