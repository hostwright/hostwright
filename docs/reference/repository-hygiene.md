# Repository closeout

Complete this procedure after a change merges. A successful merge closes the implementation work only after its branch, worktree, disposable output, and required evidence have been accounted for.

## Retire integrated branches

1. Refresh remote references with `git fetch origin --prune` and check for open pull requests.
2. Record each candidate's exact branch name and commit ID. Exclude the default branch, active work, and branches with unfinished commits.
3. Establish integration into the current `origin/main`. Git ancestry is sufficient for ordinary merges. For squash or rebase merges, verify that the branch tip exactly matches a merged PR head and that the PR's merge commit is an ancestor of current main. A closed PR alone is insufficient.
4. Recheck the remote tip and open PRs immediately before deletion. Use an explicit branch name and `git push --force-with-lease=refs/heads/BRANCH:EXPECTED_COMMIT origin :refs/heads/BRANCH` so a newly pushed commit prevents deletion. Remote branches can be retired while a local checkout remains.
5. After retiring an inactive worktree, delete its integrated local branch. Use `git branch -d BRANCH` when possible. A refusal requires reviewing the integration evidence; it does not authorize discarding unfinished work.

GitHub automatically deletes eligible PR branches after merge. Retain a private record of removed references and the reasons for exceptions. Apply the same checks to branches created outside PRs.

## Retire inactive local work

Inspect `git worktree list --porcelain`, tracked changes, untracked files, ignored files, and processes using each checkout. Keep unique commits and unfinished changes in place. Use the application's archive controls for managed worktrees; worktrees owned by another chat need cleanup through that owner.

Before removing an ordinary worktree, establish that its commit is integrated and that it has no unique files, active processes, submodules, or retained evidence. Remove only explicitly identified disposable files, then use `git worktree remove PATH`. Never use force to bypass unexplained content. Do not prune registrations for an unmounted external volume.

SwiftPM builds, dependency checkouts, and test directories can contain modified source or executed qualification products. Inspect their contents and evidence references before removing them. Reproducible caches and bytecode can be reclaimed when inactive. A build directory's name or age does not prove it is disposable.

Treat runtime databases, WAL files, locks, containers, volumes, and Keychain material as application state. Use the ownership, preview, and confirmation procedures in [local recovery](local-recovery.md) and [local paths](local-paths.md) rather than deleting their files directly.

## Retain release evidence

Map local output and Actions artifacts to their producer run, source commit, consumers, and release evidence. Preserve signed releases, source and license bundles, SBOMs, attestations, source locks, and executed qualification evidence while referenced. Keep failure diagnostics required by an unresolved qualification. Retention expiry or duplicate filenames alone do not establish safe deletion.

Record measured space reclaimed and any retained exceptions. Scan source, history, and relevant text diagnostics without logging credentials or verifying them against providers. Keep reports private and use [private disclosure](../../SECURITY.md) for confirmed security findings.

## Maintain protections

Main requires PRs and the `latest-macos-build`, `test`, and `runtime-provenance` checks from GitHub Actions. Main and published version tags reject destructive updates. New security checks should become required only after their baseline succeeds on the supported runners.

Pin external actions to verified commit IDs, disable checkout credential persistence, and grant tokens only the permissions used by each job. Review dependency updates together with the runtime source locks and provenance tests; updating a module manifest alone does not qualify a new release.

Outside-contributor workflows require approval for every run. A release environment approval and a runner label do not restrict which workflows can schedule a repository-level runner. Release runners require effective workflow restrictions and isolation from development data and credentials; verify actual runner membership in any restricted group. Changes that move a runner, rotate credentials, or interrupt a service require an explicit maintenance decision.
