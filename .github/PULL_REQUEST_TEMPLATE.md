## Summary

What changed?

## Scope

What is intentionally out of scope?

## Safety

- [ ] No runtime mutation was added, or mutation goes through `RuntimeAdapter`.
- [ ] No destructive operation was added without dry-run and confirmation design.
- [ ] No unsupported compatibility claim was added.
- [ ] No secrets are introduced in code, docs, examples, or tests.

## Verification

```bash
swift build
swift test
scripts/grep-orchard.sh .
```

