---
name: Engineering task
about: Track a scoped Hostwright engineering task
title: ""
labels: ""
assignees: ""
---

## Outcome

Describe the user-visible result and what currently prevents it.

## Scope

List affected behavior, dependencies, and consequential compatibility or security constraints.

## Acceptance criteria

- [ ] The requested behavior works and public claims match verified support.
- [ ] Relevant normal, failure, recovery, and cleanup paths pass.

## Verification

Required evidence classes: replace with the applicable classes from the [evidence rules](../../docs/reference/testing-evidence.md).

List commands, environments, and expected results. Keep live resources disposable and ownership-scoped.

## Closure

Follow the [evidence requirements](../../docs/roadmap/v0.0.2/IMPLEMENTATION_PLAN.md). Final closure requires clean source-bound evidence, the `<!-- hostwright-evidence-gate:v1 -->` record, and a `status:verification` PR. Intermediate PRs use `Refs`.
