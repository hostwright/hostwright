#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOSTWRIGHT_BIN="${HOSTWRIGHT_BIN:-$ROOT_DIR/.build/debug/hostwright}"
CONTAINER_BIN="${CONTAINER_BIN:-$(command -v container || true)}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
IMAGE="docker.io/library/python:alpine"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hostwright-runtime-identity.XXXXXXXXXXXX")"
SUFFIX="p$(printf '%s' "${WORK_DIR##*.}" | tr '[:upper:]' '[:lower:]')"
PROJECT_A="a-b-$SUFFIX"
SERVICE_A="c"
PROJECT_B="a"
SERVICE_B="b-$SUFFIX-c"
MANIFEST_A="$WORK_DIR/a.yaml"
MANIFEST_B="$WORK_DIR/b.yaml"
STATE_A="$WORK_DIR/a.sqlite"
STATE_B="$WORK_DIR/b.sqlite"
RESOURCE_A=""
RESOURCE_B=""
NORMAL_CLEANUP_COMPLETE=0
MUTATION_STARTED=0

report_error() {
    echo "FAILED: live runtime identity proof stopped at line $1." >&2
}

cleanup_project() {
    local manifest="$1"
    local state="$2"
    [ -f "$manifest" ] || return 0
    [ -f "$state" ] || return 0

    local attempt dry_run token
    for attempt in $(seq 1 30); do
        dry_run="$($HOSTWRIGHT_BIN cleanup "$manifest" --state-db "$state" --dry-run 2>/dev/null || true)"
        token="$(printf '%s\n' "$dry_run" | sed -n 's/^Confirmation token: //p' | head -1)"
        if [ -n "$token" ] && printf '%s\n' "$dry_run" | grep -q '\[eligible\]'; then
            "$HOSTWRIGHT_BIN" cleanup "$manifest" --state-db "$state" --confirm-cleanup "$token" >/dev/null
            return 0
        fi
        sleep 1
    done
    return 1
}

cleanup_on_exit() {
    local status=$?
    local cleanup_succeeded=1
    if [ "$status" -ne 0 ] && [ "$NORMAL_CLEANUP_COMPLETE" -eq 0 ] && [ "$MUTATION_STARTED" -eq 1 ]; then
        cleanup_project "$MANIFEST_A" "$STATE_A" || cleanup_succeeded=0
        cleanup_project "$MANIFEST_B" "$STATE_B" || cleanup_succeeded=0
    fi
    if [ "$status" -eq 0 ] || [ "$cleanup_succeeded" -eq 1 ]; then
        rm -rf "$WORK_DIR"
    else
        echo "FAILED: cleanup did not complete; retained proof state at $WORK_DIR." >&2
    fi
    exit "$status"
}
trap cleanup_on_exit EXIT
trap 'report_error $LINENO' ERR

if [ -z "$CONTAINER_BIN" ] || [ ! -x "$CONTAINER_BIN" ]; then
    echo "BLOCKED: Apple container CLI is unavailable." >&2
    exit 2
fi
if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
    echo "BLOCKED: python3 is unavailable for proof assertions." >&2
    exit 2
fi
if [ ! -x "$HOSTWRIGHT_BIN" ]; then
    echo "BLOCKED: built hostwright executable is unavailable at $HOSTWRIGHT_BIN." >&2
    exit 2
fi

CONTAINER_VERSION="$($CONTAINER_BIN --version)"
if ! printf '%s\n' "$CONTAINER_VERSION" | grep -q 'version 1\.0\.0'; then
    echo "BLOCKED: proof is reviewed for Apple container 1.0.0, found $CONTAINER_VERSION." >&2
    exit 2
fi

"$CONTAINER_BIN" image list --format json > "$WORK_DIR/images.json"
"$PYTHON_BIN" - "$WORK_DIR/images.json" "$IMAGE" <<'PY'
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))
names = {
    item.get("configuration", {}).get("name")
    for item in items
    if isinstance(item, dict)
}
if sys.argv[2] not in names:
    raise SystemExit("BLOCKED: required local image is unavailable; proof will not pull it.")
PY

"$CONTAINER_BIN" list --all --format json > "$WORK_DIR/before.json"

cat > "$MANIFEST_A" <<EOF
version: 2
project: $PROJECT_A

services:
  $SERVICE_A:
    image: $IMAGE
    command: ["sleep", "20"]
    restart:
      policy: on-failure
EOF

cat > "$MANIFEST_B" <<EOF
version: 2
project: $PROJECT_B

services:
  $SERVICE_B:
    image: $IMAGE
    command: ["sleep", "20"]
    restart:
      policy: on-failure
EOF

"$HOSTWRIGHT_BIN" status "$MANIFEST_A" --state-db "$STATE_A" --output json > "$WORK_DIR/plan-a.json"
"$HOSTWRIGHT_BIN" status "$MANIFEST_B" --state-db "$STATE_B" --output json > "$WORK_DIR/plan-b.json"
"$PYTHON_BIN" - "$WORK_DIR/plan-a.json" "$WORK_DIR/plan-b.json" "$WORK_DIR/before.json" > "$WORK_DIR/plan-values.txt" <<'PY'
import json
import sys

before = {item["id"] for item in json.load(open(sys.argv[3], encoding="utf-8"))}
resources = []
for path in sys.argv[1:3]:
    report = json.load(open(path, encoding="utf-8"))
    actions = report.get("actions", [])
    if len(actions) != 1 or actions[0].get("kind") != "createMissingService":
        raise SystemExit("proof requires one createMissingService action before mutation")
    resource = actions[0].get("resourceIdentifier")
    plan_hash = report.get("planHash")
    if not resource or not plan_hash:
        raise SystemExit("proof plan omitted its exact resource identifier or plan hash")
    if resource in before:
        raise SystemExit(f"proof refuses to mutate pre-existing resource {resource}")
    resources.append(resource)
    print(resource)
    print(plan_hash)
if resources[0] == resources[1]:
    raise SystemExit("versioned resource identifiers collided")
PY

RESOURCE_A="$(sed -n '1p' "$WORK_DIR/plan-values.txt")"
PLAN_HASH_A="$(sed -n '2p' "$WORK_DIR/plan-values.txt")"
RESOURCE_B="$(sed -n '3p' "$WORK_DIR/plan-values.txt")"
PLAN_HASH_B="$(sed -n '4p' "$WORK_DIR/plan-values.txt")"
[ "hostwright-$PROJECT_A-$SERVICE_A" = "hostwright-$PROJECT_B-$SERVICE_B" ]

apply_current_plan() {
    local manifest="$1"
    local state="$2"
    local status_output plan_hash
    status_output="$($HOSTWRIGHT_BIN status "$manifest" --state-db "$state")"
    plan_hash="$(printf '%s\n' "$status_output" | sed -n 's/^Plan hash: //p' | head -1)"
    [ -n "$plan_hash" ]
    printf '%s\n' "$status_output"
    "$HOSTWRIGHT_BIN" apply "$manifest" --state-db "$state" --confirm-plan "$plan_hash"
}

MUTATION_STARTED=1
CREATE_A="$("$HOSTWRIGHT_BIN" apply "$MANIFEST_A" --state-db "$STATE_A" --confirm-plan "$PLAN_HASH_A")"
CREATE_B="$("$HOSTWRIGHT_BIN" apply "$MANIFEST_B" --state-db "$STATE_B" --confirm-plan "$PLAN_HASH_B")"

[ -n "$RESOURCE_A" ]
[ -n "$RESOURCE_B" ]
[ "$RESOURCE_A" != "$RESOURCE_B" ]
[ "$(printf '%s\n' "$CREATE_A" | sed -n 's/^Resource: //p' | head -1)" = "$RESOURCE_A" ]
[ "$(printf '%s\n' "$CREATE_B" | sed -n 's/^Resource: //p' | head -1)" = "$RESOURCE_B" ]

apply_current_plan "$MANIFEST_A" "$STATE_A" >/dev/null
apply_current_plan "$MANIFEST_B" "$STATE_B" >/dev/null

"$CONTAINER_BIN" list --all --format json > "$WORK_DIR/running.json"
"$PYTHON_BIN" - "$WORK_DIR/running.json" \
    "$RESOURCE_A" "$PROJECT_A" "$SERVICE_A" \
    "$RESOURCE_B" "$PROJECT_B" "$SERVICE_B" <<'PY'
import json
import sys

items = {item["id"]: item for item in json.load(open(sys.argv[1], encoding="utf-8"))}
for offset in (2, 5):
    resource, project, service = sys.argv[offset:offset + 3]
    item = items.get(resource)
    if item is None:
        raise SystemExit(f"missing proof resource {resource}")
    labels = item.get("configuration", {}).get("labels", {})
    expected = {
        "dev.hostwright.managed": "true",
        "dev.hostwright.identity-version": "2",
        "dev.hostwright.project": project,
        "dev.hostwright.service": service,
        "dev.hostwright.resource-id": resource,
    }
    for key, value in expected.items():
        if labels.get(key) != value:
            raise SystemExit(f"label mismatch for {resource}: {key}")
PY

NETWORK_VERIFIED=0
for attempt in $(seq 1 20); do
    "$CONTAINER_BIN" list --all --format json > "$WORK_DIR/network-runtime.json"
    "$HOSTWRIGHT_BIN" status "$MANIFEST_A" --state-db "$STATE_A" --output json > "$WORK_DIR/status-a.json"
    if "$PYTHON_BIN" - "$WORK_DIR/network-runtime.json" "$WORK_DIR/status-a.json" "$RESOURCE_A" <<'PY'
import json
import sys

items = {item["id"]: item for item in json.load(open(sys.argv[1], encoding="utf-8"))}
runtime_networks = items.get(sys.argv[3], {}).get("status", {}).get("networks", [])
report = json.load(open(sys.argv[2], encoding="utf-8"))
observed = report["services"][0].get("observed") or {}
if observed.get("resourceIdentifier") != sys.argv[3]:
    raise SystemExit(1)
networks = observed.get("networks", [])
if not runtime_networks or not networks or not runtime_networks[0].get("ipv4Address"):
    raise SystemExit(1)
expected = runtime_networks[0]
actual = networks[0]
field_map = {
    "network": "name",
    "hostname": "hostname",
    "ipv4Address": "ipv4Address",
    "ipv4Gateway": "ipv4Gateway",
    "ipv6Address": "ipv6Address",
    "macAddress": "macAddress",
    "mtu": "mtu",
}
if any(actual.get(target) != expected.get(source) for source, target in field_map.items()):
    raise SystemExit(1)
PY
    then
        NETWORK_VERIFIED=1
        break
    fi
    sleep 1
done
if [ "$NETWORK_VERIFIED" -ne 1 ]; then
    cat "$WORK_DIR/status-a.json" >&2
    exit 1
fi

"$HOSTWRIGHT_BIN" status "$MANIFEST_B" --state-db "$STATE_B" --output json > "$WORK_DIR/status-b.json"
"$CONTAINER_BIN" list --all --format json > "$WORK_DIR/network-final.json"
"$PYTHON_BIN" - "$WORK_DIR/network-final.json" "$WORK_DIR/status-a.json" "$WORK_DIR/status-b.json" "$RESOURCE_A" "$RESOURCE_B" <<'PY'
import json
import sys

items = {item["id"]: item for item in json.load(open(sys.argv[1], encoding="utf-8"))}
first = json.load(open(sys.argv[2], encoding="utf-8"))["services"][0]["observed"]
second = json.load(open(sys.argv[3], encoding="utf-8"))["services"][0]["observed"]
if first["resourceIdentifier"] != sys.argv[4] or second["resourceIdentifier"] != sys.argv[5]:
    raise SystemExit("project observation did not preserve exact resource identity")
field_map = {
    "network": "name",
    "hostname": "hostname",
    "ipv4Address": "ipv4Address",
    "ipv4Gateway": "ipv4Gateway",
    "ipv6Address": "ipv6Address",
    "macAddress": "macAddress",
    "mtu": "mtu",
}
for resource, observed in ((sys.argv[4], first), (sys.argv[5], second)):
    runtime_networks = items.get(resource, {}).get("status", {}).get("networks", [])
    networks = observed.get("networks", [])
    if not runtime_networks or not networks:
        raise SystemExit("Apple container 1.0.0 network metadata was not preserved")
    expected = runtime_networks[0]
    actual = networks[0]
    if any(actual.get(target) != expected.get(source) for source, target in field_map.items()):
        raise SystemExit(f"network metadata mismatch for {resource}")
PY

for attempt in $(seq 1 30); do
    "$CONTAINER_BIN" list --all --format json > "$WORK_DIR/states.json"
    if "$PYTHON_BIN" - "$WORK_DIR/states.json" "$RESOURCE_A" "$RESOURCE_B" <<'PY'
import json
import sys

items = {item["id"]: item for item in json.load(open(sys.argv[1], encoding="utf-8"))}
states = [items.get(resource, {}).get("status", {}).get("state") for resource in sys.argv[2:]]
raise SystemExit(0 if all(state in {"created", "stopped", "exited"} for state in states) else 1)
PY
    then
        break
    fi
    sleep 1
done

cleanup_project "$MANIFEST_A" "$STATE_A"
cleanup_project "$MANIFEST_B" "$STATE_B"
NORMAL_CLEANUP_COMPLETE=1

"$CONTAINER_BIN" list --all --format json > "$WORK_DIR/after.json"
"$PYTHON_BIN" - "$WORK_DIR/before.json" "$WORK_DIR/after.json" "$RESOURCE_A" "$RESOURCE_B" <<'PY'
import json
import sys

def identifiers(path):
    return {item["id"] for item in json.load(open(path, encoding="utf-8"))}

before = identifiers(sys.argv[1])
after = identifiers(sys.argv[2])
missing = before - after
if missing:
    raise SystemExit(f"pre-existing runtime identifiers disappeared: {sorted(missing)}")
for resource in sys.argv[3:]:
    if resource in after:
        raise SystemExit(f"proof resource remains after cleanup: {resource}")
PY

echo "PROOF_STATUS=passed"
echo "RESOURCE_A=$RESOURCE_A"
echo "RESOURCE_B=$RESOURCE_B"
echo "LEGACY_COLLISION=hostwright-$PROJECT_A-$SERVICE_A"
echo "NETWORK_METADATA=Apple-container-1.0.0"
echo "CONTAINER_VERSION=$CONTAINER_VERSION"
echo "CLEANUP_STATUS=succeeded"
