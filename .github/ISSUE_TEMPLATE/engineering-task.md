---
name: Engineering task
about: Track a scoped Hostwright engineering task
title: ""
labels: ""
assignees: ""
---

## Goal

What needs to change?

## Scope

What is included?

## Out of scope

What must not be changed?

## Acceptance criteria

- [ ] Tests cover changed behavior.
- [ ] Docs are updated if public behavior changes.
- [ ] Runtime mutation, if any, goes through `RuntimeAdapter`.
- [ ] Destructive behavior, if any, has dry-run and confirmation design.
- [ ] Unsupported behavior remains explicit and no public support claim was added without implementation.
- [ ] Security/governance review triggers are listed when risky areas are touched.

## Verification

Commands to run:

```bash
swift build
swift test list || swift test --list-tests
swift test
scripts/grep-orchard.sh .
scripts/test.sh
scripts/lint.sh
```
