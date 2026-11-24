# V3-14 VM results

- VM macOS version and build:
- Signing certificate type:
- Both trials used the same signed build 1/build 2 pair:
- Fresh privacy baselines used separate GUI accounts or a restored snapshot:

| Observation | TCP (46214) | QUIC over UDP (46215) |
|---|---|---|
| Fresh Local Network state confirmed for the trial's GUI account | | |
| LaunchAgent running in the GUI domain | | |
| Reference listener readiness and on-link route verified | | |
| QUIC listener certificate copied from the running reference listener | — | |
| QUIC listener restart and reinstalled pin, if applicable: time and resumed observation | — | |
| Path status and unsatisfied reason during first connection, if reported | | |
| Build 1 first attempt time and dial result | | |
| First prompt time, exact displayed app name and message | | |
| Consent choice and first successful build 1 reply | | |
| Local Network settings entry after build 1 | | |
| New build 1 reply after reboot and GUI login | | |
| Post-reboot prompt and settings entry | | |
| Matching signing requirement and distinct executable UUIDs confirmed | | |
| Build 2 installed at the same path | | |
| Build 2 first attempt and first successful reply | | |
| Post-upgrade prompt, attribution and settings entry | | |
| Consent persisted across reboot | | |
| Consent persisted across the same-identity upgrade | | |
| D16 re-consent and LocalNetworkDenied required or still inconclusive | | |
