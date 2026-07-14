# Risk Register

| ID | Risk | Impact | Current control | Status |
| --- | --- | --- | --- | --- |
| RISK-001 | Runtime behavior is inferred instead of verified. | Incorrect mutation could damage user workloads. | Runtime behavior crosses `RuntimeAdapter`; the narrow mutation gates require live observation, exact identity/ownership, confirmation, and durable intent. Broader lifecycle remains blocked. | Open |
| RISK-002 | Old codename leaks into public-facing docs. | Naming confusion and credibility risk. | `scripts/grep-orchard.sh` scans for accidental references. | Open |
| RISK-003 | Apple container CLI is not installed locally. | Runtime doctor and adapter behavior cannot be verified. | Document limitation; keep adapter non-mutating. | Open |
| RISK-004 | SQLite durability or filesystem handling loses/corrupts local authority. | Lost ownership and recovery evidence could make mutation unsafe. | Schema v7, secure default paths, strict permissions, checksummed migrations, and journaled legacy moves are implemented; backup/repair/disk-fault and soak evidence remain issues #114/#115. | Open |
| RISK-005 | Networking scope expands into DNS, tunnels, or LAN exposure. | Security exposure and unreliable local behavior. | Current mutation remains loopback-first; Phase 07 owns implemented policy, identity, lifecycle, and cleanup rather than an undocumented expansion. | Open |
| RISK-006 | Brand assets are mistaken for final production assets. | Incorrect public presentation. | Asset README marks PNGs as source material only. | Open |
| RISK-007 | `hostwrightd` appears to be an installable daemon. | Users may expect background runtime behavior. | Daemon runs only with explicit `--foreground --config <path>`, uses a secure selected state/lock, and does not install a launch agent or mutate runtime. | Open |
| RISK-008 | Legacy/default state paths conflict or cross an unsafe filesystem boundary. | Hostwright could select the wrong authority or expose state. | Path precedence is explicit; unsafe chains fail closed; migration requires a compatible ledger, exclusive SQLite lock, same filesystem, identity journal, and unambiguous source/destination. Unknown files are preserved. | Open |
