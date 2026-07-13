# v0.0.2 Workstream Index

> Generated deterministically from `issues.json` by `scripts/render-roadmap-index.py`. Edit GitHub/`issues.json`, then regenerate; do not hand-edit this file.

Master: [#284](https://github.com/hostwright/hostwright/issues/284) — Hostwright v0.0.2 implementation roadmap and release gate

Ledger: 15 phase epics, 167 child workstreams, 183 total roadmap issues.

## Phase 01 — Truth reset, architecture contracts, and verification constitution

Epic: [#110](https://github.com/hostwright/hostwright/issues/110)

| Marker | Issue | Workstream |
| --- | ---: | --- |
| `P01-C01` | [#103](https://github.com/hostwright/hostwright/issues/103) | Align release and version truth for v0.0.2 |
| `P01-C02` | [#104](https://github.com/hostwright/hostwright/issues/104) | Separate immutable release documentation from current-main documentation |
| `P01-C03` | [#105](https://github.com/hostwright/hostwright/issues/105) | Implement the v0.0.2 gap and evidence taxonomy |
| `P01-C04` | [#106](https://github.com/hostwright/hostwright/issues/106) | Lock resource identity, backend binding, and operation saga architecture |
| `P01-C05` | [#107](https://github.com/hostwright/hostwright/issues/107) | Version Manifest, Control API, Runtime Provider, plugin, and state contracts |
| `P01-C06` | [#108](https://github.com/hostwright/hostwright/issues/108) | Enforce cross-repository website, docs, links, and quickstart checks |
| `P01-C07` | [#109](https://github.com/hostwright/hostwright/issues/109) | Enforce GitHub evidence-gated issue and PR closure |

## Phase 02 — Trusted installation, secure local foundation, and durable state

Epic: [#120](https://github.com/hostwright/hostwright/issues/120)

| Marker | Issue | Workstream |
| --- | ---: | --- |
| `P02-C01` | [#111](https://github.com/hostwright/hostwright/issues/111) | Ship the vendor Homebrew tap and production formula |
| `P02-C02` | [#112](https://github.com/hostwright/hostwright/issues/112) | Ship signed and notarized archives and macOS packages |
| `P02-C03` | [#113](https://github.com/hostwright/hostwright/issues/113) | Adopt secure macOS Application Support defaults |
| `P02-C04` | [#114](https://github.com/hostwright/hostwright/issues/114) | Implement state backup, restore, integrity check, and repair |
| `P02-C05` | [#115](https://github.com/hostwright/hostwright/issues/115) | Harden SQLite files, transactions, and local state ownership |
| `P02-C06` | [#116](https://github.com/hostwright/hostwright/issues/116) | Harden subprocess execution, cancellation, and process-tree cleanup |
| `P02-C07` | [#117](https://github.com/hostwright/hostwright/issues/117) | Turn `hostwright doctor` into a real readiness and remediation command |
| `P02-C08` | [#118](https://github.com/hostwright/hostwright/issues/118) | Implement safe upgrade, rollback, repair, and uninstall workflows |
| `P02-C09` | [#119](https://github.com/hostwright/hostwright/issues/119) | Publish release SBOM, checksums, provenance, and verification tooling |

## Phase 03 — Apple `container` and Containerization runtime conformance

Epic: [#129](https://github.com/hostwright/hostwright/issues/129)

| Marker | Issue | Workstream |
| --- | ---: | --- |
| `P03-C01` | [#121](https://github.com/hostwright/hostwright/issues/121) | Implement versioned Apple CLI structured codecs |
| `P03-C02` | [#122](https://github.com/hostwright/hostwright/issues/122) | Implement runtime capability negotiation and compatibility reporting |
| `P03-C03` | [#123](https://github.com/hostwright/hostwright/issues/123) | Implement complete Apple runtime observation |
| `P03-C04` | [#124](https://github.com/hostwright/hostwright/issues/124) | Normalize runtime processes, errors, timeouts, and cancellation |
| `P03-C05` | [#125](https://github.com/hostwright/hostwright/issues/125) | Build the pinned out-of-process Containerization helper |
| `P03-C06` | [#126](https://github.com/hostwright/hostwright/issues/126) | Build the cross-provider runtime conformance suite |
| `P03-C07` | [#127](https://github.com/hostwright/hostwright/issues/127) | Enforce project-generation backend binding and safe provider migration |
| `P03-C08` | [#128](https://github.com/hostwright/hostwright/issues/128) | Recover safely across Apple runtime and provider upgrades |

## Phase 04 — Manifest v2 and complete single-host lifecycle

Epic: [#140](https://github.com/hostwright/hostwright/issues/140)

| Marker | Issue | Workstream |
| --- | ---: | --- |
| `P04-C01` | [#130](https://github.com/hostwright/hostwright/issues/130) | Replace the restricted parser with maintained YAML |
| `P04-C02` | [#131](https://github.com/hostwright/hostwright/issues/131) | Implement the complete Manifest v2 workload schema |
| `P04-C03` | [#132](https://github.com/hostwright/hostwright/issues/132) | Implement the durable operation DAG and saga engine |
| `P04-C04` | [#133](https://github.com/hostwright/hostwright/issues/133) | Implement dependency-aware multi-service reconciliation |
| `P04-C05` | [#134](https://github.com/hostwright/hostwright/issues/134) | Implement complete lifecycle commands |
| `P04-C06` | [#135](https://github.com/hostwright/hostwright/issues/135) | Implement exec, attach, copy, export, inspect, stats, and log follow |
| `P04-C07` | [#136](https://github.com/hostwright/hostwright/issues/136) | Implement typed startup, readiness, and liveness probes |
| `P04-C08` | [#137](https://github.com/hostwright/hostwright/issues/137) | Implement rolling and recreate update strategies |
| `P04-C09` | [#138](https://github.com/hostwright/hostwright/issues/138) | Implement automatic rollback and rollout recovery |
| `P04-C10` | [#139](https://github.com/hostwright/hostwright/issues/139) | Ship executable end-to-end lifecycle examples |

## Phase 05 — Images, registries, secrets, and supply-chain trust

Epic: [#152](https://github.com/hostwright/hostwright/issues/152)

| Marker | Issue | Workstream |
| --- | ---: | --- |
| `P05-C01` | [#141](https://github.com/hostwright/hostwright/issues/141) | Implement the complete OCI image lifecycle |
| `P05-C02` | [#142](https://github.com/hostwright/hostwright/issues/142) | Implement registry login, challenges, and token refresh |
| `P05-C03` | [#143](https://github.com/hostwright/hostwright/issues/143) | Implement production Keychain secret CRUD |
| `P05-C04` | [#144](https://github.com/hostwright/hostwright/issues/144) | Implement configuration and secret provider contracts |
| `P05-C05` | [#145](https://github.com/hostwright/hostwright/issues/145) | Implement immutable image digest locks |
| `P05-C06` | [#146](https://github.com/hostwright/hostwright/issues/146) | Implement OCI referrer discovery and retention |
| `P05-C07` | [#147](https://github.com/hostwright/hostwright/issues/147) | Enforce image signature and trust policy |
| `P05-C08` | [#148](https://github.com/hostwright/hostwright/issues/148) | Generate, ingest, and bind image SBOMs |
| `P05-C09` | [#149](https://github.com/hostwright/hostwright/issues/149) | Enforce vulnerability policy with explainable decisions |
| `P05-C10` | [#150](https://github.com/hostwright/hostwright/issues/150) | Generate and verify build provenance |
| `P05-C11` | [#151](https://github.com/hostwright/hostwright/issues/151) | Implement content leases, cache pressure, and safe garbage collection |

## Phase 06 — Persistent storage and data protection

Epic: [#163](https://github.com/hostwright/hostwright/issues/163)

| Marker | Issue | Workstream |
| --- | ---: | --- |
| `P06-C01` | [#153](https://github.com/hostwright/hostwright/issues/153) | Implement named-volume lifecycle and ownership |
| `P06-C02` | [#154](https://github.com/hostwright/hostwright/issues/154) | Implement guarded bind, read-only, and tmpfs mounts |
| `P06-C03` | [#155](https://github.com/hostwright/hostwright/issues/155) | Define and ship the volume-provider SPI |
| `P06-C04` | [#156](https://github.com/hostwright/hostwright/issues/156) | Implement volume snapshots and restore points |
| `P06-C05` | [#157](https://github.com/hostwright/hostwright/issues/157) | Implement verified online backup and restore |
| `P06-C06` | [#158](https://github.com/hostwright/hostwright/issues/158) | Implement quotas, capacity accounting, and storage pressure policy |
| `P06-C07` | [#159](https://github.com/hostwright/hostwright/issues/159) | Implement attachment fencing and concurrency control |
| `P06-C08` | [#160](https://github.com/hostwright/hostwright/issues/160) | Implement reclaim and retention policy |
| `P06-C09` | [#161](https://github.com/hostwright/hostwright/issues/161) | Discover, quarantine, and garbage-collect storage orphans |
| `P06-C10` | [#162](https://github.com/hostwright/hostwright/issues/162) | Implement CSI-like internal storage semantics |

## Phase 07 — Networking, DNS, ingress, policy, and secure tunnels

Epic: [#178](https://github.com/hostwright/hostwright/issues/178)

| Marker | Issue | Workstream |
| --- | ---: | --- |
| `P07-C01` | [#164](https://github.com/hostwright/hostwright/issues/164) | Implement isolated project networks |
| `P07-C02` | [#165](https://github.com/hostwright/hostwright/issues/165) | Implement network lifecycle ownership and recovery |
| `P07-C03` | [#166](https://github.com/hostwright/hostwright/issues/166) | Implement service DNS and aliases |
| `P07-C04` | [#167](https://github.com/hostwright/hostwright/issues/167) | Implement TCP and UDP transport semantics |
| `P07-C05` | [#168](https://github.com/hostwright/hostwright/issues/168) | Implement IPv4 and IPv6 dual-stack behavior |
| `P07-C06` | [#169](https://github.com/hostwright/hostwright/issues/169) | Implement published ports and Unix sockets |
| `P07-C07` | [#170](https://github.com/hostwright/hostwright/issues/170) | Implement guarded workload access to host services |
| `P07-C08` | [#171](https://github.com/hostwright/hostwright/issues/171) | Implement explicit LAN exposure policy |
| `P07-C09` | [#172](https://github.com/hostwright/hostwright/issues/172) | Implement reverse proxy and ingress routing |
| `P07-C10` | [#173](https://github.com/hostwright/hostwright/issues/173) | Implement TLS certificate lifecycle |
| `P07-C11` | [#174](https://github.com/hostwright/hostwright/issues/174) | Implement mTLS workload and node identity |
| `P07-C12` | [#175](https://github.com/hostwright/hostwright/issues/175) | Implement ingress and egress network policy |
| `P07-C13` | [#176](https://github.com/hostwright/hostwright/issues/176) | Implement Hostwright-to-Hostwright secure tunnels |
| `P07-C14` | [#177](https://github.com/hostwright/hostwright/issues/177) | Define and ship the third-party tunnel-provider SPI |
| `P07-C15` | [#84](https://github.com/hostwright/hostwright/issues/84) | Verify Apple container localhost forwarding after Local Network permission |

## Phase 08 — Autonomous daemon, health, recovery, observability, and garbage collection

Epic: [#194](https://github.com/hostwright/hostwright/issues/194)

| Marker | Issue | Workstream |
| --- | ---: | --- |
| `P08-C01` | [#179](https://github.com/hostwright/hostwright/issues/179) | Implement the complete LaunchAgent lifecycle |
| `P08-C02` | [#180](https://github.com/hostwright/hostwright/issues/180) | Implement level-triggered unattended reconciliation |
| `P08-C03` | [#181](https://github.com/hostwright/hostwright/issues/181) | Implement secure configuration watch and reload |
| `P08-C04` | [#182](https://github.com/hostwright/hostwright/issues/182) | Implement restart budgets and crash-loop holds |
| `P08-C05` | [#183](https://github.com/hostwright/hostwright/issues/183) | Implement maintenance windows and change deferral |
| `P08-C06` | [#184](https://github.com/hostwright/hostwright/issues/184) | Implement health-gated unattended rollout |
| `P08-C07` | [#185](https://github.com/hostwright/hostwright/issues/185) | Implement autonomous rollback and safe holds |
| `P08-C08` | [#186](https://github.com/hostwright/hostwright/issues/186) | Implement mutation checkpoint recovery |
| `P08-C09` | [#187](https://github.com/hostwright/hostwright/issues/187) | Implement ownership, finalizers, and leases |
| `P08-C10` | [#188](https://github.com/hostwright/hostwright/issues/188) | Implement retention, compaction, and state maintenance |
| `P08-C11` | [#189](https://github.com/hostwright/hostwright/issues/189) | Integrate structured redacted OSLog |
| `P08-C12` | [#190](https://github.com/hostwright/hostwright/issues/190) | Implement durable event history and watches |
| `P08-C13` | [#191](https://github.com/hostwright/hostwright/issues/191) | Implement bounded metrics and SLO instrumentation |
| `P08-C14` | [#192](https://github.com/hostwright/hostwright/issues/192) | Implement correlated traces across control and runtime operations |
| `P08-C15` | [#193](https://github.com/hostwright/hostwright/issues/193) | Implement privacy-safe diagnostic support bundles |

## Phase 09 — Control API, identity, RBAC, admission, audit, and secure extensions

Epic: [#206](https://github.com/hostwright/hostwright/issues/206)

| Marker | Issue | Workstream |
| --- | ---: | --- |
| `P09-C01` | [#195](https://github.com/hostwright/hostwright/issues/195) | Implement the persistent Unix-socket Control API |
| `P09-C02` | [#196](https://github.com/hostwright/hostwright/issues/196) | Achieve complete CLI and Control API parity |
| `P09-C03` | [#197](https://github.com/hostwright/hostwright/issues/197) | Implement streaming, watches, backpressure, and recovery |
| `P09-C04` | [#198](https://github.com/hostwright/hostwright/issues/198) | Implement local authentication and peer identity |
| `P09-C05` | [#199](https://github.com/hostwright/hostwright/issues/199) | Implement least-privilege RBAC |
| `P09-C06` | [#200](https://github.com/hostwright/hostwright/issues/200) | Implement admission validation and mutation policy |
| `P09-C07` | [#201](https://github.com/hostwright/hostwright/issues/201) | Implement immutable tamper-evident audit |
| `P09-C08` | [#202](https://github.com/hostwright/hostwright/issues/202) | Implement secure workload profiles |
| `P09-C09` | [#203](https://github.com/hostwright/hostwright/issues/203) | Ship the capability-limited WASI provider SDK |
| `P09-C10` | [#204](https://github.com/hostwright/hostwright/issues/204) | Implement the signed XPC provider boundary |
| `P09-C11` | [#205](https://github.com/hostwright/hostwright/issues/205) | Implement plugin discovery, install, update, revoke, and quarantine |

## Phase 10 — Scheduler, optimization, pressure management, and accelerators

Epic: [#219](https://github.com/hostwright/hostwright/issues/219)

| Marker | Issue | Workstream |
| --- | ---: | --- |
| `P10-C01` | [#207](https://github.com/hostwright/hostwright/issues/207) | Implement requests, limits, reservations, and admission |
| `P10-C02` | [#208](https://github.com/hostwright/hostwright/issues/208) | Implement hard placement filters |
| `P10-C03` | [#209](https://github.com/hostwright/hostwright/issues/209) | Implement multi-resource best-fit-decreasing packing |
| `P10-C04` | [#210](https://github.com/hostwright/hostwright/issues/210) | Implement dominant-resource fairness |
| `P10-C05` | [#211](https://github.com/hostwright/hostwright/issues/211) | Implement topology, affinity, and anti-affinity scoring |
| `P10-C06` | [#212](https://github.com/hostwright/hostwright/issues/212) | Implement priority, preemption, and disruption budgets |
| `P10-C07` | [#213](https://github.com/hostwright/hostwright/issues/213) | Implement anti-churn hysteresis and placement stability |
| `P10-C08` | [#214](https://github.com/hostwright/hostwright/issues/214) | Implement scheduler explainability and simulation |
| `P10-C09` | [#215](https://github.com/hostwright/hostwright/issues/215) | Implement thermal, battery, sleep, and pressure policy |
| `P10-C10` | [#216](https://github.com/hostwright/hostwright/issues/216) | Implement Apple VM memory-reclamation strategy |
| `P10-C11` | [#217](https://github.com/hostwright/hostwright/issues/217) | Implement accelerator inventory and reservations |
| `P10-C12` | [#218](https://github.com/hostwright/hostwright/issues/218) | Implement the host-native Metal, Core ML, and MLX service |

## Phase 11 — Multi-Mac consensus, high availability, and remote operations

Epic: [#235](https://github.com/hostwright/hostwright/issues/235)

| Marker | Issue | Workstream |
| --- | ---: | --- |
| `P11-C01` | [#220](https://github.com/hostwright/hostwright/issues/220) | Implement cluster bootstrap, join, leave, and membership changes |
| `P11-C02` | [#221](https://github.com/hostwright/hostwright/issues/221) | Implement cluster CA and mTLS identity lifecycle |
| `P11-C03` | [#222](https://github.com/hostwright/hostwright/issues/222) | Operate a Hostwright-managed pinned etcd 3.7.x ensemble |
| `P11-C04` | [#223](https://github.com/hostwright/hostwright/issues/223) | Implement authoritative replicated desired state |
| `P11-C05` | [#224](https://github.com/hostwright/hostwright/issues/224) | Implement authenticated node agents |
| `P11-C06` | [#225](https://github.com/hostwright/hostwright/issues/225) | Implement fenced remote execution and streaming |
| `P11-C07` | [#226](https://github.com/hostwright/hostwright/issues/226) | Enforce cluster fencing tokens on every mutation |
| `P11-C08` | [#227](https://github.com/hostwright/hostwright/issues/227) | Extend scheduler placement across Macs |
| `P11-C09` | [#228](https://github.com/hostwright/hostwright/issues/228) | Implement cordon, drain, maintenance, and node removal |
| `P11-C10` | [#229](https://github.com/hostwright/hostwright/issues/229) | Implement cross-host service discovery |
| `P11-C11` | [#230](https://github.com/hostwright/hostwright/issues/230) | Implement safe remote volumes |
| `P11-C12` | [#231](https://github.com/hostwright/hostwright/issues/231) | Implement leader election and control-plane leases |
| `P11-C13` | [#232](https://github.com/hostwright/hostwright/issues/232) | Implement cluster failover and node-loss recovery |
| `P11-C14` | [#233](https://github.com/hostwright/hostwright/issues/233) | Implement mixed-version rolling cluster upgrades |
| `P11-C15` | [#234](https://github.com/hostwright/hostwright/issues/234) | Implement cluster disaster recovery |

## Phase 12 — Kubernetes, CRI, CNI, CSI, and Helm interoperability

Epic: [#247](https://github.com/hostwright/hostwright/issues/247)

| Marker | Issue | Workstream |
| --- | ---: | --- |
| `P12-C01` | [#236](https://github.com/hostwright/hostwright/issues/236) | Build the Hostwright pod-sandbox VM and guest agent |
| `P12-C02` | [#237](https://github.com/hostwright/hostwright/issues/237) | Implement CRI v1 RuntimeService |
| `P12-C03` | [#238](https://github.com/hostwright/hostwright/issues/238) | Implement CRI v1 ImageService |
| `P12-C04` | [#239](https://github.com/hostwright/hostwright/issues/239) | Implement CRI streaming, logs, and stats APIs |
| `P12-C05` | [#240](https://github.com/hostwright/hostwright/issues/240) | Integrate supported kubelet versions |
| `P12-C06` | [#241](https://github.com/hostwright/hostwright/issues/241) | Implement CNI in the real pod guest topology |
| `P12-C07` | [#242](https://github.com/hostwright/hostwright/issues/242) | Implement CSI controller and node adapters |
| `P12-C08` | [#243](https://github.com/hostwright/hostwright/issues/243) | Translate Kubernetes resources into Hostwright desired state |
| `P12-C09` | [#244](https://github.com/hostwright/hostwright/issues/244) | Ingest rendered Helm output safely |
| `P12-C10` | [#245](https://github.com/hostwright/hostwright/issues/245) | Integrate Kubernetes scheduling and devices |
| `P12-C11` | [#246](https://github.com/hostwright/hostwright/issues/246) | Automate Kubernetes interoperability conformance reporting |

## Phase 13 — Docker, Compose, Podman, Testcontainers, CI, and IDE interoperability

Epic: [#257](https://github.com/hostwright/hostwright/issues/257)

| Marker | Issue | Workstream |
| --- | ---: | --- |
| `P13-C01` | [#248](https://github.com/hostwright/hostwright/issues/248) | Implement the version-negotiated Docker Engine API |
| `P13-C02` | [#249](https://github.com/hostwright/hostwright/issues/249) | Implement the authenticated local Docker socket and context |
| `P13-C03` | [#250](https://github.com/hostwright/hostwright/issues/250) | Implement complete Compose import, execution, update, export, and loss reporting |
| `P13-C04` | [#251](https://github.com/hostwright/hostwright/issues/251) | Implement supported Podman client compatibility |
| `P13-C05` | [#252](https://github.com/hostwright/hostwright/issues/252) | Pass Testcontainers Java, Go, Node, Python, and .NET matrices |
| `P13-C06` | [#253](https://github.com/hostwright/hostwright/issues/253) | Ship GitHub Actions integration |
| `P13-C07` | [#254](https://github.com/hostwright/hostwright/issues/254) | Ship Xcode workflows |
| `P13-C08` | [#255](https://github.com/hostwright/hostwright/issues/255) | Ship VS Code workflows |
| `P13-C09` | [#256](https://github.com/hostwright/hostwright/issues/256) | Ship JetBrains workflows |

## Phase 14 — Native GUI, team/MDM, and optional cloud control plane

Epic: [#270](https://github.com/hostwright/hostwright/issues/270)

| Marker | Issue | Workstream |
| --- | ---: | --- |
| `P14-C01` | [#258](https://github.com/hostwright/hostwright/issues/258) | Build the signed SwiftUI app and menu-bar client |
| `P14-C02` | [#259](https://github.com/hostwright/hostwright/issues/259) | Enforce complete CLI and GUI action parity |
| `P14-C03` | [#260](https://github.com/hostwright/hostwright/issues/260) | Visualize topology, status, logs, events, metrics, and recovery |
| `P14-C04` | [#261](https://github.com/hostwright/hostwright/issues/261) | Meet the native accessibility quality gate |
| `P14-C05` | [#262](https://github.com/hostwright/hostwright/issues/262) | Implement signed native app updates and rollback |
| `P14-C06` | [#263](https://github.com/hostwright/hostwright/issues/263) | Implement team roles, approvals, and change workflow |
| `P14-C07` | [#264](https://github.com/hostwright/hostwright/issues/264) | Implement MDM deployment, managed policy, and compliance |
| `P14-C08` | [#265](https://github.com/hostwright/hostwright/issues/265) | Build the optional cloud control service |
| `P14-C09` | [#266](https://github.com/hostwright/hostwright/issues/266) | Implement PostgreSQL tenant state and data lifecycle |
| `P14-C10` | [#267](https://github.com/hostwright/hostwright/issues/267) | Implement OIDC and SSO identity lifecycle |
| `P14-C11` | [#268](https://github.com/hostwright/hostwright/issues/268) | Implement outbound-only fleet agent connections |
| `P14-C12` | [#269](https://github.com/hostwright/hostwright/issues/269) | Implement remote audit, diagnostics, and consented support |

## Phase 15 — Exhaustive qualification, documentation, and v0.0.2 GA

Epic: [#283](https://github.com/hostwright/hostwright/issues/283)

| Marker | Issue | Workstream |
| --- | ---: | --- |
| `P15-C01` | [#271](https://github.com/hostwright/hostwright/issues/271) | Freeze and test all supported-version matrices |
| `P15-C02` | [#272](https://github.com/hostwright/hostwright/issues/272) | Complete the independent security assessment and remediation gate |
| `P15-C03` | [#273](https://github.com/hostwright/hostwright/issues/273) | Run release-grade coverage-guided fuzzing |
| `P15-C04` | [#274](https://github.com/hostwright/hostwright/issues/274) | Run supported ASan and TSan qualification lanes |
| `P15-C05` | [#275](https://github.com/hostwright/hostwright/issues/275) | Enforce dependency, SAST, secret, and license gates |
| `P15-C06` | [#276](https://github.com/hostwright/hostwright/issues/276) | Qualify performance, density, energy, and regression budgets |
| `P15-C07` | [#277](https://github.com/hostwright/hostwright/issues/277) | Complete single-host and cluster disaster-recovery drills |
| `P15-C08` | [#278](https://github.com/hostwright/hostwright/issues/278) | Verify the complete upgrade lineage and rollback window |
| `P15-C09` | [#279](https://github.com/hostwright/hostwright/issues/279) | Finish and execute all documentation, website, and examples |
| `P15-C10` | [#280](https://github.com/hostwright/hostwright/issues/280) | Establish support, governance, compatibility, and incident operations |
| `P15-C11` | [#281](https://github.com/hostwright/hostwright/issues/281) | Produce and verify signed v0.0.2 GA artifacts |
| `P15-C12` | [#282](https://github.com/hostwright/hostwright/issues/282) | Submit the unqualified Homebrew-core formula |
