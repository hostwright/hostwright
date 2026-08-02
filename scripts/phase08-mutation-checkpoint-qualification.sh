#!/usr/bin/env bash
set -euo pipefail

readonly uuid_pattern='^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$'
readonly selectors=(
  'LifecycleSagaExecutorTests.testMutationCheckpointTaxonomyClassifiesEverySagaTerminalAndBoundary'
  'LifecycleLiveDriverTests.testPersistedRecoveryRefusesUnknownCheckpointBeforeMutation'
  'LifecycleProcessRecoveryIntegrationTests.testLifecycleSagaRecoversAfterSIGKILLAtDurableBoundaries'
  'LifecycleLiveDriverTests.testPersistedRollbackResumesWithoutDuplicateInverseAfterCancellation'
  'HostwrightDaemonCoreTests.testPhase08FreshDaemonRestartAttemptsAdvanceExecutionIdentityAndFence'
  'RuntimeQualificationRecoveryDriverTests.testWriterIsKilledAndFreshExecutableResumesItsDurableCheckpoint'
  'RuntimeQualificationProcessControlTests.testCrashProbeTerminatesTheObservedDescendantTree'
  'ServiceTunnelLifecycleManagerTests.testCrashRestartRecoversPersistedIntentThroughSetup'
  'StoragePruneProcessRecoveryIntegrationTests.testPruneRecoversAfterSIGKILLAroundProviderDelete'
  'SQLiteHardeningTests.testRealProcessKillDiscardsUncommittedWALAndPreservesCommittedWAL'
  'StateUpgradeTests.testSchemaV16MigratesRestartBudgetsToV17WithSafeDefaults'
  'StateUpgradeTests.testVerifiedV16SnapshotMigratesAndRestoresExactPriorSchema'
  'StorageAttachmentCoordinatorTests.testCancellationAtEveryCheckpointPreservesAResumableRecord'
  'StateMaintenanceTests.testRecoveryHandlesEveryTornRestoreMutationWindow'
  'RuntimeProviderMigrationTests.testEveryDurableCheckpointResumesWithoutDuplicateOrLostIdentity'
  'DaemonLifecycleContractTests.testEveryInstallCheckpointLeavesRepairableDurableIntent'
  'DistributionDurableLifecycleTests.testCancellationAtInstallUpgradeRepairAndUninstallCheckpointsRecoversExactly'
  'HostwrightCLITests.testRecoveryOutputIncludesVersionedLifecycleCheckpointContract'
  'MutationCheckpointQualificationScriptTests.testContractIsSerialResumableAndNonDisruptive'
)

die() {
  printf '%s\n' "$1" >&2
  exit "${2:-70}"
}

contract() {
  printf '%s\n' 'Phase 08 mutation checkpoint qualification contract v1 is valid.'
  printf '%s\n' 'Cells run serially; passing cells are reused only for the exact source digest.'
  printf '%s\n' 'A failed cell retains its raw log and does not mark itself passed.'
  printf '%s\n' 'No cell dispatches CI, reboots, logs out, or removes non-test resources.'
  printf '%s\n' "${selectors[@]}"
}

source_digest() {
  {
    git rev-parse HEAD
    git diff --binary HEAD -- . ':(exclude)tmp'
    while IFS= read -r path; do
      [[ "$path" == tmp || "$path" == tmp/* ]] && continue
      /usr/bin/shasum -a 256 "$path"
    done < <(git ls-files --others --exclude-standard | LC_ALL=C sort)
  } | /usr/bin/shasum -a 256 | awk '{ print $1 }'
}

validate_root() {
  : "${HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT:?HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT is required}"
  local account_home parent root_parent root_name user_id
  account_home="$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
  parent="${account_home}/Library/Application Support/Hostwright/qualification"
  root_parent="$(dirname "$HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT")"
  root_name="$(basename "$HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT")"
  user_id="$(id -u)"
  [[ -d "$parent" && ! -L "$parent" && "$(/bin/realpath "$parent")" == "$parent" \
      && "$(stat -f '%u' "$parent")" == "$user_id" \
      && "$(stat -f '%Lp' "$parent")" == 700 ]] \
    || die 'The qualification parent must be canonical, current-user-owned, and mode 0700.' 77
  [[ "$root_parent" == "$parent" \
      && "$root_name" =~ ^phase08-gate8-${uuid_pattern#^} \
      && -d "$HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT" \
      && ! -L "$HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT" \
      && "$(/bin/realpath "$HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT")" == "$HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT" \
      && "$(stat -f '%u' "$HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT")" == "$user_id" \
      && "$(stat -f '%Lp' "$HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT")" == 700 ]] \
    || die 'The Gate 8 root must be a canonical private phase08-gate8-<uuid> directory.' 77
}

run_matrix() {
  validate_root
  local state lock digest index selector log_file record
  state="$HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT/state-v1.tsv"
  lock="$HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT/active-run-v1"
  umask 077
  mkdir "$lock" 2>/dev/null \
    || die 'Another checkpoint qualification is active or left an inspectable run lock.' 75
  trap 'rmdir "$HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT/active-run-v1" 2>/dev/null || true' EXIT
  touch "$state"
  chmod 600 "$state"
  digest="$(source_digest)"
  index=0
  for selector in "${selectors[@]}"; do
    index=$((index + 1))
    record="${digest}"$'\t'"${selector}"$'\tpass'
    if grep -Fqx "$record" "$state"; then
      printf 'reuse pass %02d %s\n' "$index" "$selector"
      continue
    fi
    log_file="$(mktemp "$HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT/cell-${index}.log.XXXXXX")"
    chmod 600 "$log_file"
    printf 'run %02d %s log=%s\n' "$index" "$selector" "$log_file"
    (umask 022 && swift test --filter "$selector") 2>&1 | tee "$log_file"
    printf '%s\n' "$record" >> "$state"
    chmod 600 "$state"
  done
  printf 'Phase 08 mutation checkpoint qualification passed source=%s cells=%d\n' \
    "$digest" "${#selectors[@]}"
}

case "${1:-}" in
  contract)
    contract
    ;;
  run)
    [[ "$#" == 1 ]] || die 'Usage: phase08-mutation-checkpoint-qualification.sh contract|run' 64
    run_matrix
    ;;
  *)
    die 'Usage: phase08-mutation-checkpoint-qualification.sh contract|run' 64
    ;;
esac
