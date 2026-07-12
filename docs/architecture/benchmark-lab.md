# Benchmark Lab

Status: Phase 36 operational local benchmark runner with evidence-gated results.

`hostwright benchmark` can execute bounded local hardware measurements against an image that already exists in Apple container. It writes one explicit JSON report and never uploads it. The runner does not pull images, use a state database, publish benchmark numbers, infer capacity, or run in hosted CI.

## Explicit Invocation

The live path requires every input:

```bash
hostwright benchmark \
  --image docker.io/library/python:alpine \
  --samples 3 \
  --report /tmp/hostwright-benchmark.json \
  --source-commit <40-lowercase-hex> \
  --source-dirty false \
  --expected-container-version 1.0.0 \
  --confirm-live
```

The report path must not exist. Creation uses an exclusive mode-`0600` file and refuses a check/write race rather than overwriting. Sample count is bounded from 3 through 10. The image must already be local; the runtime adapter's existing local-image check blocks rather than pulling it.

## Evidence Versions

Schema version `1` remains the historical dry-run/fixture contract. It cannot represent live hardware evidence.

Schema version `2` requires:

- the typed `hardware-benchmark` evidence envelope;
- exact source commit and dirty state;
- OS description/build, architecture, hardware model, physical memory, and tool versions;
- requested local image reference, descriptor digest, selected platform-variant digest, architecture, and operating system;
- every RuntimeAdapter operation with exit status and duration;
- three or more raw iteration samples for any completed run;
- one unique versioned `hostwright-v2-bench-...` identifier per iteration;
- raw create, start, boot-observation, polling, runtime stats, thermal, and battery fields;
- every benchmark dimension exactly once;
- failures and blockers separated;
- exact cleanup identifiers and cleanup result.

A missing runtime, local image, battery, attended sleep interval, or other prerequisite is `blocked`. A command, parsing, identity, ownership, version-drift, or cleanup failure is `failed`. Neither status is a pass.

## Runtime Sequence

Each iteration:

1. Generates a collision-resistant v2 identity under the benchmark prefix.
2. Reads adapter metadata/capabilities, exact Apple container version, and local image digest/platform evidence through `RuntimeAdapter`; unexpected versions or architectures stop before mutation.
3. Observes first and refuses any collision.
4. Plans and creates one labeled Hostwright-owned container through `RuntimeAdapter`.
5. Starts a bounded `sleep` process through `RuntimeAdapter`.
6. Polls exact identity until running and records every poll duration.
7. Reads one non-streaming Apple container JSON stats sample for that exact identifier.
8. Waits for two consecutive terminal observations separated by a quiescence interval.
9. Deletes the exact identifier and verifies it is absent.

Cleanup is retried for every attempted identifier after an error. A cleanup failure makes the report fail and leaves the exact identifier in the report for manual recovery. Broad delete, force delete, image cleanup, volume cleanup, and unmanaged cleanup are unavailable.

## Measurements

- `memoryPressure`: median per-container `memoryUsageBytes` from raw Apple container stats. This is workload memory use, not a host-capacity result.
- `bootLatency`: median elapsed time from confirmed start invocation to first exact running observation.
- `pollingOverhead`: median duration of exact RuntimeAdapter observation calls during boot polling.
- `battery`: IOKit charge and power-source facts before and after the bounded run when a battery exists.
- `thermal`: ProcessInfo thermal state before, during, and after the run.
- `sleepWake`: attended wall-clock-versus-monotonic-uptime gap plus exact post-wake observation.
- `appleContainerVersionDrift`: real local version output compared with the required expected version.

Raw samples remain in the local report. Public docs must not turn one host's values into performance, efficiency, compatibility, or capacity claims.

## Attended Sleep/Wake

The runner never forces system sleep. An operator can add:

```bash
--attended-sleep-wake-seconds 30
```

The runner prints a stderr notice when the attended window opens and another when post-wake verification starts. During the first bounded iteration, it records wall time and monotonic uptime, waits for the attended window, then re-observes the exact resource. The operator must put the Mac to sleep after the open notice. Evidence is observed only when wall time exceeds monotonic uptime by at least two seconds and the exact resource is visible after wake. Otherwise sleep/wake remains blocked. The first process has a bounded 10-second cleanup margin after the attended window, within the exact-cleanup poll limit.

## Process Execution

Apple container execution stays inside `HostwrightRuntime`. The process runner drains stdout and stderr concurrently, detects process exit with `Process.terminationHandler`, bounds inherited-pipe drain time, and uses bounded TERM then KILL handling after command timeout. This avoids hangs and avoids treating complete command output as success when process termination or output closure was not observed.

## CI Policy

Hosted CI runs build, XCTest, built-CLI local integration, lint, and naming scans. It does not assume Apple container or a local image exists and does not claim hardware evidence. Contract adapters inject deterministic failures only. A reviewed local run is the only hardware-benchmark evidence path.

## Rejected Claims

Phase 36 does not claim production capacity, runtime density, VM overhead, sustained battery efficiency, sustained thermal performance, cross-version Apple container compatibility, accelerator performance, or comparative benchmark results. It does not add telemetry, image pulls, broad cleanup, release tags, GitHub Releases, website work, or GUI code.
