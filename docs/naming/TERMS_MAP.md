# Hostwright Terms Map

| Concept | Canonical term |
| --- | --- |
| Project | Hostwright |
| CLI | `hostwright` |
| Daemon | `hostwrightd` |
| Manifest | `hostwright.yaml` |
| Domain | `hostwright.dev` |
| GitHub repo name | `hostwright` |
| Swift package identity | `hostwright` |
| Log subsystem | `com.hostwright` |
| Daemon label, if a later installer is approved | `com.hostwright.daemon` |
| Config directory | `~/.hostwright/` |
| State directory | `~/Library/Application Support/Hostwright/` |
| Schema file | `hostwright-yaml.schema.json` |

## Swift Modules

| Area | Module |
| --- | --- |
| CLI | `HostwrightCLI` |
| Daemon | `HostwrightDaemon` |
| Core domain | `HostwrightCore` |
| Runtime boundary | `HostwrightRuntime` |
| Local state | `HostwrightState` |
| Reconciliation | `HostwrightReconciler` |
| Health | `HostwrightHealth` |
| Networking boundaries | `HostwrightNetworking` |
| Events/logging interfaces | `HostwrightObservability` |

## Historical Terms

| Historical term | Replacement | Rule |
| --- | --- | --- |
| Orchard | Hostwright | Historical source-material name only. |
| `orchard` | `hostwright` | Do not use in public-facing repo files. |
| `orchardd` | `hostwrightd` | Do not use in public-facing repo files. |
| `orchard.yaml` | `hostwright.yaml` | Do not use in public-facing repo files. |
| `orchard.cc` | `hostwright.dev` | Do not use in public-facing repo files. |

