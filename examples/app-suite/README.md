# Three-service reconciliation and update

`prepare` must complete before two `worker` replicas start. Both workers must become ready before `web` starts. The workers use a rolling update; the fixed localhost port makes the web update explicitly recreate.

```bash
hostwright up hostwright.yaml --dry-run --parallelism 4 --output json
hostwright up hostwright.yaml --confirm-plan "$PLAN_SHA256" --parallelism 4 --output json
hostwright update hostwright.yaml --dry-run --output json
hostwright update hostwright.yaml --confirm-plan "$PLAN_SHA256" --output json
hostwright down hostwright.yaml --dry-run --output json
hostwright down hostwright.yaml --confirm-plan "$PLAN_SHA256" --output json
hostwright rm hostwright.yaml --dry-run --output json
hostwright rm hostwright.yaml --confirm-plan "$PLAN_SHA256" --output json
```

Set `PLAN_SHA256` only from the immediately preceding dry-run result.
