# Deliberately unhealthy update

First establish `hostwright.yaml` as the verified healthy revision. Then confirm the update plan built from `unhealthy.yaml`. Its readiness probe always fails, so promotion must not succeed and the lifecycle recovery path must preserve or restore the prior verified revision.

```bash
hostwright up hostwright.yaml --dry-run --output json
hostwright up hostwright.yaml --confirm-plan "$PLAN_SHA256" --output json
hostwright update unhealthy.yaml --dry-run --output json
hostwright update unhealthy.yaml --confirm-plan "$PLAN_SHA256" --output json
hostwright recovery --project phase04-rollback --output json
hostwright inspect web --manifest hostwright.yaml --output json
```

Set `PLAN_SHA256` only from the immediately preceding dry-run result. The expected update result is failure plus automatic rollback or a precise safe hold; it is never successful promotion.
