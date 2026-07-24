# Single-service lifecycle

Prerequisite: the exact image digest in `hostwright.yaml` is already available through upstream runtime tooling.

```bash
hostwright up hostwright.yaml --dry-run
hostwright up hostwright.yaml --confirm-plan "$PLAN_SHA256"
hostwright stop hostwright.yaml --dry-run
hostwright stop hostwright.yaml --confirm-plan "$PLAN_SHA256"
hostwright start hostwright.yaml --dry-run
hostwright start hostwright.yaml --confirm-plan "$PLAN_SHA256"
hostwright restart hostwright.yaml --dry-run
hostwright restart hostwright.yaml --confirm-plan "$PLAN_SHA256"
hostwright run hostwright.yaml --service web --dry-run
hostwright run hostwright.yaml --service web --confirm-plan "$PLAN_SHA256"
hostwright down hostwright.yaml --dry-run
hostwright down hostwright.yaml --confirm-plan "$PLAN_SHA256"
hostwright rm hostwright.yaml --dry-run
hostwright rm hostwright.yaml --confirm-plan "$PLAN_SHA256"
```

For every mutation, set `PLAN_SHA256` to the exact digest emitted by the immediately preceding dry run.
