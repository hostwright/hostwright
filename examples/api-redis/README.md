# JSON automation and interactive operations

The directory name is retained for compatibility with the checked-in example corpus. The manifest contains one bounded Phase 04 service.

Non-interactive JSON sequence:

```bash
hostwright up hostwright.yaml --dry-run --output json
hostwright up hostwright.yaml --confirm-plan "$PLAN_SHA256" --output json
hostwright inspect api --manifest hostwright.yaml --output json
hostwright stats api --manifest hostwright.yaml --output json
hostwright exec api --manifest hostwright.yaml --output json -- python3 -c "print('ok')"
hostwright copy ./input.txt api:/tmp/input.txt --manifest hostwright.yaml --output json
hostwright export api /tmp/hostwright-api.tar --manifest hostwright.yaml --output json
hostwright logs api hostwright.yaml --follow --tail 20 --output json
```

Interactive text sequence:

```bash
hostwright exec api --manifest hostwright.yaml --tty -- python3
hostwright attach api --manifest hostwright.yaml
```

TTY mode intentionally has no JSON output selector. Set `PLAN_SHA256` only from the immediately preceding dry-run result.
