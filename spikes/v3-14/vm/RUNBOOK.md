# Local Network consent on the VM

Use one disposable macOS 15 or later VM with two fresh GUI accounts. Run TCP in one account and QUIC in the other. Apple documents separate Local Network privacy state per macOS user. Using the same account after granting access to the app would make the second transport's first-prompt observation inconclusive. If working with one account, restore a VM snapshot taken before app installation between the TCP and QUIC trials and save the first trial's results outside the VM before restoring. [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

Both trials use the same pair of signed app builds. Within each trial, keep the same GUI account, on-link reference machine, listener instance, bundle identifier, signer, and installed bundle path through reboot and upgrade.

## 1. Prepare the signed pair and reference listeners

On the signing Mac, use the spike branch from the issue comment and find an Apple-issued code-signing identity.

```sh
security find-identity -v -p codesigning
sw_vers
```

Record only the signing certificate type, such as `Developer ID Application` or `Apple Development`. Ad hoc signing can make a new build appear to be a different app. Keep identity names, certificate hashes, Apple IDs, and team IDs out of the results.

Build the pair once from the repo root. Read the signing identity silently so its literal name stays out of shell history. Keep the staged builds available outside the VM if using snapshot restore.

```sh
spike="$PWD/spikes/v3-14"
signed_pair="$(mktemp -d "$HOME/.v314-signed.XXXXXXXX")"
printf 'Apple-issued signing identity: '
read -rs v314_signer
printf '\n'
"$spike/vm/sign-vm-build.sh" "$v314_signer" 1 "$signed_pair/build-1.app" &&
    "$spike/vm/sign-vm-build.sh" "$v314_signer" 2 "$signed_pair/build-2.app"
unset v314_signer
```

Transfer both complete signed app bundles to a readable staging location in the VM using a trusted file-sharing path. Do not start either there. Use the same spike branch in the VM for the LaunchAgent renderer.

Build the reference binary on the physical host or another macOS machine with a private IPv4 address on the VM's link. Loopback would miss the Local Network privacy check.

```sh
swift build --package-path spikes/v3-14
bin="$(swift build --package-path spikes/v3-14 --show-bin-path)/v314-probe"
lan_peer='REPLACE_WITH_REFERENCE_MACHINE_IPV4'
```

Run the TCP reference listener in one terminal.

```sh
"$bin" listen "$lan_peer" 46214
```

Run the QUIC reference listener on UDP port 46215 in another terminal. Set `bin` and `lan_peer` to the same values.

```sh
quic_reference="$(mktemp -d "$HOME/.v314-quic.XXXXXXXX")"
"$bin" quic-listen "$lan_peer" 46215 "$quic_reference/listener.der"
```

Wait for `listen ready port=46214` and `quic listen ready port=46215 certificate=written`. Copy the **public** `listener.der` into the same trusted VM staging location as the apps before bootstrapping the QUIC LaunchAgent. The QUIC dialer verifies the reference listener's exact certificate on every handshake. Keep the same listener processes running through both reboots and upgrades if possible. If the QUIC listener restarts, follow the recovery steps below before retrying. The listeners' terminal sessions on the reference machine are outside the consent measurement.

## 2. Install build 1 and bootstrap the LaunchAgent

In the assigned VM GUI account, start in the repo root. Use `transport=tcp` in the first account and `transport=quic` in the second. Replace the staging path and listener address.

```sh
transport=tcp
staged='/REPLACE/WITH/ABSOLUTE/VM/STAGING/PATH'
lan_peer='REPLACE_WITH_REFERENCE_MACHINE_IPV4'
spike="$PWD/spikes/v3-14"
app="$HOME/Applications/HostwrightV314Probe.app"
agent_label='dev.hostwright.spike.local-network'
agent="$HOME/Library/LaunchAgents/$agent_label.plist"
logs="$HOME/Library/Logs/HostwrightV314Probe/$transport"
domain="gui/$(id -u)"

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$logs"
```

Confirm that neither the probe app nor its LaunchAgent is installed and that the app has no existing Local Network entry for this user. Install the signed bundle at its permanent test path.

```sh
test ! -e "$app" &&
    test ! -e "$agent" &&
    /usr/bin/ditto "$staged/build-1.app" "$app" &&
    codesign --verify --strict "$app"
```

Render the LaunchAgent for the selected transport. Keep the QUIC pin in the account's home directory so it remains readable after reboot.

```sh
case "$transport" in
    tcp)
        "$spike/vm/render-launch-agent.sh" "$app" "$lan_peer" 46214 "$logs" > "$agent.new"
        ;;
    quic)
        pin="$logs/listener.der"
        install -m 0644 "$staged/listener.der" "$pin" &&
            "$spike/vm/render-launch-agent.sh" "$app" "$lan_peer" 46215 "$logs" "$pin" > "$agent.new"
        ;;
esac
```

Once rendering succeeds, observe the VM desktop from before bootstrap.

```sh
plutil -lint "$agent.new" &&
    mv "$agent.new" "$agent" &&
    launchctl bootstrap "$domain" "$agent" &&
    tail -f "$logs/probe.log"
```

Record the first attempt time, any prompt and its attribution, and whether the dial log reported `waiting`, `localNetworkDenied`, a QUIC handshake error, or a successful reply before consent. If prompted, choose **Allow**, then verify a fresh build 1 `dial reply=ok` for TCP or `quic dial reply=ok` for QUIC. Check the corresponding reference listener log and record the entry in System Settings → Privacy & Security → Local Network.

The QUIC dialer logs `path_status` and `path_reason` from the same connection that does the QUIC handshake. A `waiting` line can precede a normal connection. Record `path_status=unsatisfied path_reason=localNetworkDenied` as direct path evidence of a privacy block when it appears. A `quic dial rejected reference certificate` line ends that attempt and is a certificate failure. A timeout without a Local Network path reason remains inconclusive. Compare the path log with the prompt and the Settings entry.

If no prompt appears, allow at least 60 seconds across retries. Record the actual dial outcome and verify both the fresh privacy state and the on-link route. Check that the reference listener is still running on UDP port 46215 with the installed certificate.

The probe must remain a user LaunchAgent in the GUI domain. Starting the VM dialer in Terminal or SSH, starting it as a root daemon, and using loopback can all hide the real behavior. [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

### If the QUIC reference listener restarts

Restart it on the same IP and port using a fresh output directory as in step 1. Wait for its readiness line, then transfer its new public `listener.der` into the trusted VM staging location. In the same QUIC trial account, set `domain`, `agent_label`, `agent`, `staged`, and `logs` as in step 2. Unload the active LaunchAgent before replacing the pin so the next process reads the new file.

```sh
launchctl bootout "$domain/$agent_label" &&
    install -m 0644 "$staged/listener.der" "$logs/listener.der.new" &&
    mv "$logs/listener.der.new" "$logs/listener.der" &&
    launchctl bootstrap "$domain" "$agent"
```

If the LaunchAgent is already unloaded, start with the `install` command. Keep the signed bundle and its path unchanged. Note the listener restart and pin replacement in RESULTS.md, then resume the interrupted observation after a fresh `quic dial reply=ok`.

## 3. Reboot and verify build 1

Reboot the VM and log in to the same assigned GUI account. Wait for the persistent LaunchAgent to start from `~/Library/LaunchAgents`. Verify a **new** build 1 success line for the selected transport. Check System Settings and record any new prompt. Use timestamps to distinguish new connections from old log entries.

## 4. Install build 2 in place

In the same account, set the same `staged`, `app`, `agent_label`, `agent`, `logs`, and `domain` values from step 2. Check that the designated requirements match and the executable UUIDs differ. These commands compare locally without printing the signing requirement.

```sh
upgrade="$staged/build-2.app"
v314_requirement() { codesign -d -r- "$1" 2>&1 | sed -n '/^designated => /p'; }
v314_uuid() { dwarfdump --uuid "$1/Contents/MacOS/v314-probe" | awk '/UUID:/ {print $2, $3}'; }
old_requirement="$(v314_requirement "$app")"
new_requirement="$(v314_requirement "$upgrade")"
old_uuid="$(v314_uuid "$app")"
new_uuid="$(v314_uuid "$upgrade")"
codesign --verify --strict "$upgrade" &&
    test -n "$old_requirement" && test "$old_requirement" = "$new_requirement" &&
    test -n "$old_uuid" && test -n "$new_uuid" && test "$old_uuid" != "$new_uuid" &&
    printf 'Matching signing requirements and distinct executable UUIDs\n'
unset old_requirement new_requirement old_uuid new_uuid
```

Continue only if the confirmation prints. Replace the Contents at the same installed path, then restart the same LaunchAgent. Keep the prior Contents outside the app during the test.

```sh
v314_backup="$(mktemp -d "$HOME/Applications/.v314-previous.XXXXXXXX")"
launchctl bootout "$domain/$agent_label" &&
    mv "$app/Contents" "$v314_backup/Contents" &&
    /usr/bin/ditto "$upgrade/Contents" "$app/Contents" &&
    codesign --verify --strict "$app" &&
    launchctl bootstrap "$domain" "$agent" &&
    tail -f "$logs/probe.log"
```

Record any new prompt and its attribution, the current Local Network setting, and a fresh build 2 success for this transport. If consent is requested again despite the matching designated requirement, record D16 re-consent and `LocalNetworkDenied` as required for that transport.

Finish the same steps for the other transport in its fresh GUI account or restored snapshot. Record each trial separately in the [results template](RESULTS.md). After recording the evidence, unload both test LaunchAgents, stop the two reference listeners, and remove the disposable probe files when they are no longer needed.
