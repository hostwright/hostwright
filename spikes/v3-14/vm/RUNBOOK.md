# Local Network consent on the VM

Use a disposable macOS 15 or later VM with a GUI login and a fresh privacy state for this probe. Snapshot it before installing the first build. Keep the same GUI user, virtual network, on-link peer, listener port, signed bundle identifier, signer, and installed bundle path across both versions.

The VM runs the signed dialer as a user LaunchAgent. A reference listener runs on the physical host or another macOS machine on the same private segment. Use a numeric IPv4 address the VM reaches directly on that segment. Using the VM's loopback would miss the Local Network privacy check.

Apple documents the Terminal and SSH exception, the difference between LaunchAgents and system daemons, and tracking by code signature. The probe stays alive when blocked so macOS has time to show the prompt. [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

## 1. Find a signer and start the reference listener

In the VM GUI user's Terminal, run:

```sh
security find-identity -v -p codesigning
sw_vers
```

Record the certificate type only, for example `Developer ID Application` or `Apple Development`. Select the same Apple-issued signing identity both times. Ad hoc signing can make a new build appear to be a different app. Keep names, certificate hashes, Apple IDs, and team IDs out of the results.

On the reference machine, run the listener from the repo root in its own terminal. Fill in the reference machine's IPv4 address on the VM's link:

```sh
swift build --package-path spikes/v3-14
bin="$(swift build --package-path spikes/v3-14 --show-bin-path)/v314-probe"
lan_peer='REPLACE_WITH_REFERENCE_MACHINE_IPV4'
"$bin" listen "$lan_peer" 46214
```

Wait for `listen ready port=46214`. Keep the listener running through the VM reboot and upgrade. Its Terminal session is on the reference machine and is outside the consent measurement.

## 2. Install build 1 and trigger the first connection

In the VM GUI user's Terminal, run the following from the repo root. Read the signing identity from the prompt so its literal name stays out of shell history.

```sh
spike="$PWD/spikes/v3-14"
app="$HOME/Applications/HostwrightV314Probe.app"
agent_label='dev.hostwright.spike.local-network'
agent="$HOME/Library/LaunchAgents/$agent_label.plist"
logs="$HOME/Library/Logs/HostwrightV314Probe"
domain="gui/$(id -u)"
lan_peer='REPLACE_WITH_REFERENCE_MACHINE_IPV4'
port=46214

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$logs"
```

Confirm that neither the probe app nor its LaunchAgent is installed. Use the fresh VM snapshot if an earlier probe already recorded consent.

```sh
printf 'Apple-issued signing identity: '
read -rs v314_signer
printf '\n'
"$spike/vm/sign-vm-build.sh" "$v314_signer" 1 "$app"
unset v314_signer
"$spike/vm/render-launch-agent.sh" "$app" "$lan_peer" "$port" "$logs" > "$agent"
plutil -lint "$agent"
launchctl bootstrap "$domain" "$agent"
tail -f "$logs/probe.log"
```

Observe the GUI from before bootstrap. Record whether the prompt appears, its app name and message, and whether the dial log reported `waiting`, `localNetworkDenied`, or reached `reply=ok` before consent. If prompted, choose **Allow**, then wait for the build 1 `dial reply=ok` line. Check that the reference machine logged a successful reply. Record the entry shown in System Settings → Privacy & Security → Local Network.

If no prompt appears, allow at least 60 seconds across retries. Record the actual dial outcome and verify the on-link address and fresh privacy state before drawing a conclusion. A broken route or absent listener cannot establish consent behavior.

The probe must remain a LaunchAgent in the GUI domain. Launching the dialer with Terminal or SSH, launching it as a root daemon, and testing a loopback path can all hide the real behavior.

## 3. Reboot and verify build 1

Reboot the VM and log in to the same GUI account. Wait for the persistent LaunchAgent to start from `~/Library/LaunchAgents`. Keep the reference listener running and verify a **new** build 1 `dial reply=ok` line after reboot. Check System Settings and record any new prompt. Use the timestamps to distinguish new connections from old log entries.

## 4. Install build 2 in place

In a VM Terminal at the repo root, set the same `spike`, `app`, `agent_label`, `agent`, `logs`, and `domain` values from step 2. Prepare the upgrade in a temporary directory outside the installed app:

```sh
v314_stage="$(mktemp -d "$HOME/Applications/.v314-stage.XXXXXXXX")"
printf 'The same Apple-issued signing identity: '
read -rs v314_signer
printf '\n'
"$spike/vm/sign-vm-build.sh" "$v314_signer" 2 "$v314_stage/upgrade.app"
unset v314_signer
```

Check that the designated requirements match and the Mach-O UUIDs differ. These commands compare locally without printing the signing requirement:

```sh
v314_requirement() { codesign -d -r- "$1" 2>&1 | sed -n '/^designated => /p'; }
v314_uuid() { dwarfdump --uuid "$1/Contents/MacOS/v314-probe" | awk '/UUID:/ {print $2, $3}'; }
old_requirement="$(v314_requirement "$app")"
new_requirement="$(v314_requirement "$v314_stage/upgrade.app")"
old_uuid="$(v314_uuid "$app")"
new_uuid="$(v314_uuid "$v314_stage/upgrade.app")"
test -n "$old_requirement" && test "$old_requirement" = "$new_requirement" \
    && test -n "$old_uuid" && test -n "$new_uuid" && test "$old_uuid" != "$new_uuid" \
    && printf 'Matching signing requirements and distinct executable UUIDs\n'
unset old_requirement new_requirement old_uuid new_uuid
```

Continue only if the confirmation prints. Replace the Contents at the same installed path, then restart the same LaunchAgent. The old bundle's contents are kept outside an app bundle while testing.

```sh
launchctl bootout "$domain/$agent_label"
mv "$app/Contents" "$v314_stage/previous-contents"
mv "$v314_stage/upgrade.app/Contents" "$app/Contents"
codesign --verify --strict "$app"
launchctl bootstrap "$domain" "$agent"
tail -f "$logs/probe.log"
```

Record any new prompt and its attribution, the current Local Network setting, and a fresh build 2 dial result. If an upgrade asks for consent again with the same requirement, report that D16's re-consent step and `LocalNetworkDenied` condition are required. Use the [results template](RESULTS.md) to post the measurements to the spike issue.

When finished, unload the test LaunchAgent and stop the reference listener. You can remove the test plist, installed app, and temporary build staging from the disposable VM when the results are recorded.
