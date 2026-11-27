#!/usr/bin/env bash
set -euo pipefail

readonly qualification_filter='(DistributionIntegrationTests|DistributionDurableLifecycleTests|ReleaseQualificationRegistryTests|Phase07ContainerizationNetworkLiveTests|Phase07LANExposureLiveTests|LifecycleGate05LiveTests|Phase07LocalNetworkForwardingLiveTests|Phase07NetworkGate01LiveTests)/'
readonly nightly_homebrew_filter='TrustedReleaseTests/testRenderedHomebrewFormulaPassesRealRubyAndHomebrewStyle$'
readonly pr_parallel_xctest_filter='(LifecycleLiveDriverTests|TrustedReleaseTests|'\
'ReleaseQualificationCLITests|MutationCheckpointQualificationScriptTests|DaemonLocalLifecycleAuthorityTests|'\
'NetworkHelperIngressBrokerTests|HostwrightDaemonCoreTests|PersistentControlStreamIntegrationTests|'\
'SecureSubprocessTests|SchedulerAdmissionRepositoryTests|HostwrightCLITests|PluginControlOperationsTests|'\
'LifecycleSchedulerSDKFenceTests|LocalSchedulerDaemonLifecycleTests)/'
readonly durable_lifecycle_sentinel_filter='DistributionDurableLifecycleTests/(testLegacyRollbackPostRestoreCancellationAndInterruptionRecoverCurrentGeneration|testPackageLifecycleUsesExistingRepairUpgradeRollbackAndDowngradeRules|testInterruptedUpgradeRecoversThenUpgradeAndVerifiedRollbackRestoreBinaryAndState|testRequiredOperationRejectsLockedStateMismatchWithoutMutation|testRemoveDataRequiresCurrentPlanAndInterruptedRemovalRestoresPayloadAndState|testManagedServiceSymlinkExecutableIsRejectedBeforeLifecycleMutation)$'

usage() {
  cat <<'EOF'
usage: scripts/test.sh [full|pr|pr-build|pr-tests|qualification <shard>]

qualification shards:
  distribution
  release
  live
  homebrew
  all (excludes the nightly-only Homebrew case)

Set HOSTWRIGHT_TEST_RESULTS_DIR to write one xUnit XML file per Swift test invocation.
EOF
}

swift_test() {
  local result_name="$1"
  shift

  if [[ -n "${HOSTWRIGHT_TEST_RESULTS_DIR:-}" ]]; then
    mkdir -p "$HOSTWRIGHT_TEST_RESULTS_DIR"
    scripts/ci-swift.sh test --jobs 3 "$@" --xunit-output "$HOSTWRIGHT_TEST_RESULTS_DIR/$result_name.xml"
    return
  fi

  scripts/ci-swift.sh test --jobs 3 "$@"
}

run_cheap_checks() {
  python3 scripts/test-shell-assertions.py
  python3 scripts/release/test-homebrew-cask.py
  python3 scripts/release/test-staged-release.py
  python3 scripts/release/test-validate-run.py
  python3 scripts/release/test-assemble-qualification.py
  python3 scripts/release/test-swift-test-results.py
  python3 scripts/release/test-supported-suite-matrix.py
  python3 scripts/release/test_qualify_vendor_tap.py
  python3 scripts/roadmap-governance.py validate
  python3 scripts/roadmap-governance.py self-test
  python3 scripts/render-roadmap-index.py check
  python3 scripts/check-current-truth.py
  python3 scripts/check-current-truth.py --self-test
  scripts/lint.sh
}

run_full() {
  run_cheap_checks
  swift build --jobs 3
  python3 scripts/test-docker-proxy.py "$(swift build --show-bin-path)/hostwright-docker-proxy"
  swift_test full
  scripts/integration.sh
  scripts/check-docs.sh
}

run_pr_build() {
  scripts/ci-swift.sh build --jobs 3
}

run_pr_tests() {
  local excluded_filter="$qualification_filter|$nightly_homebrew_filter"

  python3 scripts/test-docker-proxy.py "$(swift build --show-bin-path)/hostwright-docker-proxy"
  scripts/integration.sh
  swift_test pr-fast --skip "$excluded_filter|$pr_parallel_xctest_filter"
  swift_test pr-parallel-xctest --skip-build --disable-swift-testing --parallel --num-workers 3 \
    --filter "$pr_parallel_xctest_filter" --skip "$excluded_filter"
  swift_test pr-durable-lifecycle-sentinels --filter "$durable_lifecycle_sentinel_filter"
}

run_pr() {
  run_cheap_checks
  run_pr_build
  run_pr_tests
}

run_qualification() {
  local shard="$1"
  local filter

  case "$shard" in
    distribution)
      filter='(DistributionIntegrationTests|DistributionDurableLifecycleTests)/'
      ;;
    release)
      filter='ReleaseQualificationRegistryTests/'
      ;;
    live)
      filter='(Phase07ContainerizationNetworkLiveTests|Phase07LANExposureLiveTests|LifecycleGate05LiveTests|Phase07LocalNetworkForwardingLiveTests|Phase07NetworkGate01LiveTests)/'
      ;;
    homebrew)
      # SwiftPM can omit XCTest xUnit output.
      swift_test qualification-homebrew --disable-swift-testing --filter "$nightly_homebrew_filter" 2>&1 |
        awk -v expected="'-[HostwrightDistributionTests.TrustedReleaseTests testRenderedHomebrewFormulaPassesRealRubyAndHomebrewStyle]'" '
          /^Test Case / {
            if ($0 ~ /\]\047 started\.$/) started++
            if ($0 ~ /\]\047 (passed|failed|skipped) \(/) completed++
            if (index($0, "Test Case " expected " passed (") == 1) passed++
          }
          { print }
          END {
            if (started != 1 || completed != 1 || passed != 1) {
              print "Expected exactly one passing Homebrew qualification case: " expected > "/dev/stderr"
              exit 1
            }
          }'
      return
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
  pr-build)
    [[ "$#" == 1 ]] || { usage >&2; exit 64; }
    run_pr_build
    ;;
  pr-tests)
    [[ "$#" == 1 ]] || { usage >&2; exit 64; }
    run_cheap_checks
    run_pr_tests
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
