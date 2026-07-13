## Outcome

What user-visible or operational result does this deliver?

## Scope

What contract, resource, workflow, or failure path changes? If work is sequenced into another roadmap phase, link that issue instead of calling it a non-goal.

## Issue

Refs #...

Use `Refs #NN` for research, design, documentation, partial implementation, and intermediate slices. Only a final evidence-gate PR with the `status:verification` label may use `Closes #NN`.

## Public Contracts And Migrations

- Contract/version changes:
- Compatibility window:
- State/data migration:
- Rollback window:

## Threat And Failure Model

- Trust boundaries touched:
- Expected failures and injected faults:
- Secret, identity, authorization, ownership, and cleanup impact:

## Recovery And Rollback

- Recovery path:
- Compensating actions:
- Rollback procedure:

## Safety

- [ ] No runtime mutation was added, or mutation goes through `RuntimeAdapter`.
- [ ] No destructive operation was added without dry-run and confirmation design.
- [ ] No unsupported compatibility claim was added.
- [ ] No secrets are introduced in code, docs, examples, or tests.
- [ ] Managed resources have exact identity, ownership, and cleanup behavior; unmanaged resources cannot be mutated or deleted.
- [ ] External exposure is authenticated and fail-closed; telemetry is explicit opt-in.
- [ ] Risky areas from `GOVERNANCE.md` and `SECURITY.md` received maintainer review or are not touched.

## Evidence Classes

- [ ] `unit-contract`
- [ ] `local-integration`
- [ ] `live-runtime`
- [ ] `hardware-benchmark`
- [ ] `distribution-artifact`
- [ ] `migration-upgrade`
- [ ] `security-assessment`
- [ ] `resilience-chaos`
- [ ] `multi-host`
- [ ] `interop-conformance`
- [ ] `ux-accessibility`

Mark only classes required by the linked issue and attach raw evidence or artifact links.

## Verification

```bash
swift build
swift test list || swift test --list-tests
swift test
scripts/grep-orchard.sh .
scripts/test.sh
scripts/lint.sh
```

## Final Evidence Gate

Delete this section for intermediate PRs. A final closure PR must carry `status:verification` and complete every field.

<!-- hostwright-evidence-gate:v1 -->

- Commit:
- Dirty: true
- OS/build/architecture/hardware:
- Runtime/framework/tool versions:
- Commands and raw outcomes:
- Failures:
- Blockers:
- Cleanup and exact resource identifiers:
- Required evidence artifacts: list every class declared by the linked issue with its result or artifact
- Documentation and compatibility matrix updates:
