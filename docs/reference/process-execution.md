# Secure Process Execution

Status: implemented for v0.0.2 Phase 02 issue #116.

Hostwright uses one bounded subprocess foundation for Apple runtime commands, distribution tooling, local tool inspection, and the reviewed-local extension handshake. Production code does not use `Foundation.Process` and never constructs a shell command string.

## Execution Flow

```mermaid
flowchart LR
    A["Typed caller request"] --> B["Caller policy and redaction"]
    B --> C["Verified executable identity"]
    C --> D["Minimal exact environment"]
    D --> E["Descriptor-pinned working directory"]
    E --> F["Suspended posix_spawn in a new session"]
    F --> G["Post-spawn identity verification"]
    G --> H["Bounded nonblocking I/O monitor"]
    H --> I["Exit, timeout, cancellation, or limit"]
    I --> J["Owned process-group cleanup before reap"]
    J --> K["Typed result or redaction-safe caller error"]
```

The launch sequence is deliberately ordered:

1. Validate time, byte, argument, environment, and working-directory limits.
2. Stop immediately when cancellation was already requested.
3. Resolve named tools only through absolute PATH entries whose complete path chain and executable are root-owned. The first unsafe candidate fails closed; Hostwright does not skip to a later candidate.
4. For an explicit executable, canonicalize the path and require a nonempty regular executable owned by root or the invoking user, with no group/world write bits, set-ID bits, or script interpreter header. Shell and `env` dispatch executables are refused.
5. Open and validate the working directory, then pass its descriptor to `posix_spawn_file_actions_addfchdir`; a later path or symlink swap cannot redirect the child working directory.
6. Create close-on-exec pipes, use exact argv and a complete caller-supplied environment, start a new session with inherited descriptors closed by default, and initially suspend the child.
7. Recheck the executable device, inode, ownership, mode, size, modification time, and change time before continuing it.
8. Drain stdout and stderr and write stdin without blocking. Enforce separate byte limits, a wall-clock timeout, task/token cancellation, and a bounded TERM-to-KILL escalation.
9. Observe leader exit with `waitid(..., WNOWAIT)` without immediately reaping it. This keeps its PID and process-group identity fenced while Hostwright sends the final group cleanup signal. Reap only afterward, wait for group and pipe convergence, and never signal a reused PID or process group.

## Default Contract

| Field | Default or bound |
| --- | --- |
| PATH | `/usr/bin:/bin:/usr/sbin:/sbin` exactly |
| Locale | `LANG=C`, `LC_ALL=C` |
| Timeout | 30 seconds by default; 1 ms to 24 hours accepted by the core request |
| Termination grace | 1 second by default; 10 ms to 5 seconds accepted |
| stdout | 8 MiB default; 1 byte to 64 MiB |
| stderr | 8 MiB default; 1 byte to 64 MiB |
| stdin | 1 MiB default; 0 to 16 MiB |
| argv | At most 4,096 arguments and 1 MiB of UTF-8 data |
| environment | At most 512 ASCII-named entries and 256 KiB |

The runtime and distribution adapters choose narrower limits where their contracts require them. Runtime command timeouts remain clamped to 1–300 seconds. Distribution commands accept 1–86,400 seconds and refuse values that could overflow conversion to milliseconds.

The environment is constructed from an empty baseline; parent variables do not leak. Dynamic-loader variables, language startup hooks, shell startup hooks, and environment-dispatch overrides are rejected. `HOME`, when present, must be a normalized absolute path. Secrets are never added to argv by this layer. For Apple container creation, resolved `secretEnv` values are carried only in the bounded child environment and the CLI receives `--env KEY`, using its documented inherit-from-host form; Hostwright never emits `--env KEY=secret`. Callers that intentionally place sensitive values in an environment must register them with their redaction policy before any result can be displayed or persisted.

## Errors and Recovery

The core reports distinct failures for invalid requests, unsafe executable/working-directory identity, launch setup, launch failure, executable replacement, timeout, cancellation, output overflow, input/output I/O failure, wait failure, unexpected descendants, and cleanup non-convergence.

On timeout, cancellation, I/O failure, or output overflow, Hostwright closes stdin, signals the owned session process group with `SIGTERM`, escalates to `SIGKILL` after the configured grace period, drains bounded output, reaps the leader, and verifies that the inherited process group and pipes converge. A pre-launch cancellation creates no child. If `SIGKILL` cannot converge within the cleanup window, the call fails as `processTreeCleanupFailed` and installs an asynchronous leader reap so a later exit does not become a zombie.

Runtime errors redact sensitive values and partial output before crossing `RuntimeAdapter`. Distribution and extension callers do not expose raw captured output from boundary failures.

## Migration From the Pre-v0.0.2 Runner

`FoundationRuntimeProcessRunner` was removed and replaced by `SecureRuntimeProcessRunner`. This is an intentional pre-1.0 source-breaking rename. Callers must:

- construct typed `RuntimeCommandSpec` values and use `SecureRuntimeProcessRunner` for runtime work;
- use `SecureSubprocessRunner` only for a reviewed non-runtime boundary with explicit limits;
- handle cancellation, output-limit, and process-tree errors separately from timeout and ordinary nonzero exit;
- stop relying on inherited environment variables or a PATH-selected user-owned executable;
- use normalized absolute working-directory paths with safe ownership and permissions.

There is no compatibility alias because preserving the predecessor's narrower timeout-and-capture contract would let production callers bypass the new executable, environment, descriptor, cancellation, and cleanup guarantees.

## Exact Security Boundary

Session process-group cleanup covers the leader and descendants that remain in the inherited session/process group, including children that ignore `SIGTERM`. macOS does not provide a public, entitlement-free primitive that turns an arbitrary native subprocess into a hostile-code containment boundary. Reviewed-local native extensions still execute with the invoking account's ambient privileges and can deliberately create a new session. They must therefore be treated as operator-trusted code. Capability-limited WASI and signed XPC isolation are owned by Phase 09 issues #203 and #204; Hostwright does not claim those protections here and does not use private Apple process APIs.

## Evidence

The 419-test repository suite includes real-process coverage for literal shell metacharacters, root-only PATH resolution, unsafe permissions/ownership, executable mutation, lexical traversal, descriptor-pinned working directories, parent-environment isolation, sensitive values outside argv, loader hooks, non-ASCII environment names, bounded stdin round-trip, early stdin closure, stdout/stderr floods, low and high descriptor inheritance, timeout, pre-launch and in-flight cancellation, cancellation races, leader/descendant cleanup, ignored `SIGTERM`, rapid exits, distribution lifecycle execution, and reviewed-local extension execution. The complete 21-test secure-subprocess suite also passes under AddressSanitizer and ThreadSanitizer. Live Apple-runtime evidence ran a read-only Hostwright status workflow through Apple container 1.0.0; the normalized inventory hash was `deb226ad125d10ec1e2f7c50e2cd4b4a890a51944e94bb63f2e8d422302ce73d` before and after, and the temporary manifest/state were removed exactly.
