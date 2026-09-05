#!/usr/bin/env bash
set -euo pipefail

readonly qualification_filter='(DistributionIntegrationTests|DistributionDurableLifecycleTests|Phase09Gate13QualificationHarnessTests|Phase09Gate14QualificationHarnessTests|Phase09Gate15QualificationHarnessTests|Phase09Gate16QualificationHarnessTests|ReleaseQualificationRegistryTests|Phase07ContainerizationNetworkLiveTests|Phase07LANExposureLiveTests|LifecycleGate05LiveTests|Phase07LocalNetworkForwardingLiveTests|Phase07NetworkGate01LiveTests)/'
readonly durable_lifecycle_sentinel_filter='DistributionDurableLifecycleTests/(testPackageLifecycleUsesExistingRepairUpgradeRollbackAndDowngradeRules|testInterruptedUpgradeRecoversThenUpgradeAndVerifiedRollbackRestoreBinaryAndState|testRequiredOperationRejectsLockedStateMismatchWithoutMutation|testRemoveDataRequiresCurrentPlanAndInterruptedRemovalRestoresPayloadAndState|testManagedServiceSymlinkExecutableIsRejectedBeforeLifecycleMutation)$'

usage() {
  cat <<'EOF'
usage: scripts/test.sh [full|pr|qualification <shard>]

qualification shards:
  distribution
  phase09-gate13
  phase09-gate14
  phase09-other
  release
  live
  all

Set HOSTWRIGHT_TEST_RESULTS_DIR to write one xUnit XML file per Swift test invocation.
EOF
}

swift_test() {
  local result_name="$1"
  shift

  if [[ -n "${HOSTWRIGHT_TEST_RESULTS_DIR:-}" ]]; then
    mkdir -p "$HOSTWRIGHT_TEST_RESULTS_DIR"
    swift test "$@" --xunit-output "$HOSTWRIGHT_TEST_RESULTS_DIR/$result_name.xml"
    return
  fi

  swift test "$@"
}

run_cheap_checks() {
  python3 scripts/roadmap-governance.py validate
  python3 scripts/roadmap-governance.py self-test
  python3 scripts/render-roadmap-index.py check
  python3 scripts/check-current-truth.py
  scripts/lint.sh
  scripts/grep-orchard.sh .
}

run_full() {
  run_cheap_checks
  swift build
  swift_test full
  scripts/integration.sh
  scripts/check-docs.sh
}

run_pr() {
  run_cheap_checks
  swift build
  scripts/integration.sh
  swift_test pr-fast --skip "$qualification_filter"
  swift_test pr-durable-lifecycle-sentinels --filter "$durable_lifecycle_sentinel_filter"
}

run_qualification() {
  local shard="$1"
  local filter

  case "$shard" in
    distribution)
      filter='(DistributionIntegrationTests|DistributionDurableLifecycleTests)/'
      ;;
    phase09-gate13)
      filter='Phase09Gate13QualificationHarnessTests/'
      ;;
    phase09-gate14)
      filter='Phase09Gate14QualificationHarnessTests/'
      ;;
    phase09-other)
      filter='(Phase09Gate15QualificationHarnessTests|Phase09Gate16QualificationHarnessTests)/'
      ;;
    release)
      filter='ReleaseQualificationRegistryTests/'
      ;;
    live)
      filter='(Phase07ContainerizationNetworkLiveTests|Phase07LANExposureLiveTests|LifecycleGate05LiveTests|Phase07LocalNetworkForwardingLiveTests|Phase07NetworkGate01LiveTests)/'
      ;;
    all)
      filter="$qualification_filter"
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac

  case "$shard" in
    distribution|all)
      swift_test "qualification-$shard" --filter "$filter" --skip "$durable_lifecycle_sentinel_filter"
      ;;
    *)
      swift_test "qualification-$shard" --filter "$filter"
      ;;
  esac
}

if [[ "$#" == 0 ]]; then
  run_full
  exit
fi

case "$1" in
  -h|--help)
    [[ "$#" == 1 ]] || { usage >&2; exit 64; }
    usage
    ;;
  full)
    [[ "$#" == 1 ]] || { usage >&2; exit 64; }
    run_full
    ;;
  pr)
    [[ "$#" == 1 ]] || { usage >&2; exit 64; }
    run_pr
    ;;
  qualification)
    [[ "$#" == 2 ]] || { usage >&2; exit 64; }
    run_qualification "$2"
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
