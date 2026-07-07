# Risk Register

| ID | Risk | Impact | Current control | Status |
| --- | --- | --- | --- | --- |
| RISK-001 | Runtime behavior is inferred instead of verified. | Incorrect mutation could damage user workloads. | RuntimeAdapter exists only as a boundary; no mutation implemented. | Open |
| RISK-002 | Old codename leaks into public-facing docs. | Naming confusion and credibility risk. | `scripts/grep-orchard.sh` scans for accidental references. | Open |
| RISK-003 | Apple container CLI is not installed locally. | Runtime doctor and adapter behavior cannot be verified. | Document limitation; keep adapter non-mutating. | Open |
| RISK-004 | SQLite dependency choice is premature. | Bad persistence abstraction or dependency churn. | State interfaces exist; implementation deferred. | Open |
| RISK-005 | Networking scope expands into DNS, tunnels, or LAN exposure. | Security exposure and unreliable local behavior. | Networking docs classify these as deferred. | Open |
| RISK-006 | Brand assets are mistaken for final production assets. | Incorrect public presentation. | Asset README marks PNGs as source material only. | Open |
| RISK-007 | `hostwrightd` appears to be an installable daemon. | Users may expect background runtime behavior. | Daemon runs only with explicit `--foreground --config <path> --state-db <path>` and does not install a launch agent or mutate runtime. | Open |
