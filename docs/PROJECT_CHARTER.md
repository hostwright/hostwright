# Project scope

Hostwright manages container workloads on one Apple silicon Mac. The first release covers the CLI, local CPU/memory admission, narrow Compose import, and a native desktop console. [ADR 0015](design/adr-0015-reduced-local-release.md) records that scope and its deferrals.

Runtime providers isolate Apple container access. SQLite stores local intent, ownership, and recovery records. Mutations require reviewed plans, current authority, and verified outcomes. The [release plan](roadmap/v0.0.2/IMPLEMENTATION_PLAN.md) and [compatibility matrix](reference/compatibility.md) define the remaining qualification requirements.
