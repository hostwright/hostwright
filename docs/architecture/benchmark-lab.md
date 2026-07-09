# Benchmark Lab

Status: Phase 36 local dry-run and fixture-backed benchmark lab.

Phase 36 adds benchmark report contracts, fixture parsing, and CI/docs gates. It does not run live Apple container benchmarks, pull images, create containers, mutate runtime state, upload telemetry, or make performance claims.

## Report Contract

Benchmark reports use schema version `1` and record:

- profile identifier;
- timestamp supplied by the benchmark runner;
- hardware, OS, Apple container, and workload profile from resource intelligence;
- disposable-resource policy;
- observations for memory pressure, boot latency, polling overhead, battery, thermal state, sleep/wake, and Apple container version drift;
- explicit limits.

Every benchmark dimension must be present. A dimension that was not measured must use `unmeasured`.

## Disposable Resource Policy

Benchmark reports fail closed unless their resource policy says:

- disposable resource names use a `hostwright-` prefix;
- resources must be Hostwright-owned;
- image pulls are not allowed by default;
- runtime mutation is not allowed by default;
- broad cleanup is not allowed;
- cleanup instructions use exact resource identifiers.

Future live benchmark commands must use disposable Hostwright-owned resources only and must require reviewed cleanup instructions before any runtime mutation.

## CI Policy

Hosted CI runs build, tests, lint, and the naming scan. It does not assume Apple container is installed on the runner and does not run live benchmarks.

Apple container version drift is tracked through reviewed fixtures and explicit local reports until a later approved RuntimeAdapter-backed probe exists.

## Fixture Policy

Benchmark fixtures must:

- use schema version `1`;
- avoid raw secrets, local user paths, private host identifiers, and personal data;
- label every measured and unmeasured dimension;
- state whether image pulls and runtime mutation were allowed;
- keep resource names disposable and Hostwright-owned;
- avoid benchmark numbers without environment facts.

## Blocked Evidence

Current core does not measure:

- runtime density;
- VM-per-container overhead;
- boot latency;
- polling overhead;
- battery behavior;
- sleep/wake behavior;
- workload memory pressure;
- Apple container version drift from live commands.

Those require a separate approved live benchmark command, disposable resources, exact cleanup proof, and maintainer review.

## Rejected Claims

Phase 36 does not claim:

- production capacity;
- performance comparison results;
- benchmark numbers;
- Apple container version compatibility guarantees;
- automatic placement or resource reservation;
- cloud telemetry;
- hosted performance monitoring.
