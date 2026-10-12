# Desktop Quickstart

Use the signed CLI, daemon and `Hostwright.app` from the same current candidate
installation. The public dev.12 qualification release uses older contracts.
Current-candidate live desktop qualification is still pending.

## Prepare the service

Follow the [CLI quickstart](../../README.md#quick-start) to save its Manifest v3,
bootstrap identities, start the foreground daemon and pull the pinned Python
image. Stop before running the CLI `up` commands. Use a unique project name and
an available host port. Keep the manifest file and daemon terminal open.

Use the current user's default [local paths](../reference/local-paths.md) for
this desktop walkthrough. The app and daemon must connect to the same local
state. Identity bootstrap registers the desktop executable as well as the CLI
and control companion.

For the signed package's standard installation, open the app with:

```sh
open /usr/local/libexec/hostwright/Hostwright.app
```

For an explicit archive installation, open `libexec/hostwright/Hostwright.app`
inside that installation's managed prefix. See the
[installed lifecycle](../reference/installed-lifecycle.md).

## Start, inspect and stop

1. In **Overview**, check the connection status. If disconnected, use
   **Reconnect** after checking the daemon terminal for an error.
2. Select **Choose manifest** and open the same absolute `hostwright.yaml` used
   by the daemon. Check the displayed project and `web` service.
3. Check the CPU and memory limits in the saved manifest. Select **Start** and
   review the manifest/hash, action, service, resource and plan digest shown in
   the confirmation sheet, then select **Confirm Start**. Cancel if the project or changes
   do not match the file you chose. If the file or observed state changes, obtain
   a fresh preview before confirming.
4. Select **Refresh status** and inspect the service lifecycle and resource ID.
   In a terminal, run `curl --fail http://127.0.0.1:18080/`, using your chosen
   host port. A displayed running state alone does not verify the HTTP service.
5. Use **Open logs for web** in the service table's Logs column to inspect the
   finite log stream. The HTTP request should appear in the Python server log.
6. Select **Stop**, review the new plan and select **Confirm Stop**. Refresh
   status to verify that the service stopped.

## Remove the stopped workload

The desktop stops a workload; removal uses the CLI. From the manifest directory,
review and confirm removal using the fresh plan hash:

```sh
hostwright rm hostwright.yaml --dry-run --runtime-provider apple-cli
hostwright rm hostwright.yaml --confirm-plan <rm-plan-hash> --runtime-provider apple-cli
hostwright status hostwright.yaml --runtime-provider apple-cli
```

Verify the owned resource is absent, quit Hostwright, and press Control-C in the
foreground daemon terminal if you started it for this walkthrough. Keep the
manifest and local state; do not remove unrelated provider resources.
