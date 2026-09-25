# Website and documentation

The core repository owns command contracts, examples, compatibility, and release requirements. The separate [hostwright.dev repository](https://github.com/hostwright/hostwright.dev) owns the website and documentation presentation.

## Sources

| Content | Reference |
| --- | --- |
| Installation and package lifecycle | [Install](../reference/install.md), [installed lifecycle](../reference/installed-lifecycle.md) |
| Commands and examples | [CLI](../reference/cli.md), [manifest](../reference/manifest.md), checked-in examples |
| Supported behavior | [Compatibility](../reference/compatibility.md), [limitations](../reference/limitations.md), `hostwright capabilities --json` |
| Operations | [Daemon](daemon.md), [state recovery](../reference/local-recovery.md), [support bundles](../reference/support-bundles.md) |
| Release scope and publication | [Release plan](../roadmap/v0.0.2/IMPLEMENTATION_PLAN.md), [release process](../release/RELEASE_PROCESS.md) |

Keep installation, versions, support claims, and limitations consistent across both repositories. Tutorials must use commands exercised on the recorded release candidate and explain required setup and confirmation. Preserve historical release notes unchanged.

## Verification and hosting

Run the website root and documentation project's typecheck, build, link checks, and dependency audit. Execute the CLI, Compose, and desktop quickstarts. Review changed pages at desktop and mobile sizes, then verify deployed content after publication.

The root site uses GitHub Pages; the documentation site uses its existing Cloudflare Pages project. Keep their deployment configuration in the website repository. Access or deployment failures remain explicit release blockers when they prevent public documentation from matching the qualified product.
