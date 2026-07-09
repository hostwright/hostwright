## Summary

What changed?

## Scope

What is intentionally out of scope?

## Issue

Closes #...

## Safety

- [ ] No runtime mutation was added, or mutation goes through `RuntimeAdapter`.
- [ ] No destructive operation was added without dry-run and confirmation design.
- [ ] No unsupported compatibility claim was added.
- [ ] No secrets are introduced in code, docs, examples, or tests.
- [ ] No release tag, GitHub Release, website implementation, GUI code, cloud/tunnel/DNS behavior, external orchestrator compatibility, multi-host mutation, or accelerator support was added.
- [ ] Risky areas from `GOVERNANCE.md` and `SECURITY.md` received maintainer review or are not touched.

## Verification

```bash
swift build
swift test list || swift test --list-tests
swift test
scripts/grep-orchard.sh .
scripts/test.sh
scripts/lint.sh
```
