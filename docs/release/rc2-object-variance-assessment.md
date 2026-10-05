# Retained RC.2 intermediate-object variance

This assessment reads the retained build pair without rebuilding or changing it.
It belongs to historical `0.0.2-rc.2`, source
`751d8d771bf1e74a01e30b30c22c5f6843d4b70d`, trusted staging run
`37281269383`, attempt `1`. It cannot qualify subsequent source or artifacts.

## Observations

Both `objects/SystemPackage.build/SystemString.swift.o` files contain 105,064
bytes. Their SHA-256 values are:

| Generation | SHA-256 |
| --- | --- |
| 1 | `9bc6cc7b554ee365c877a2a344a5fd09ec9d65f0fa51930b90be045905afac85` |
| 2 | `321996a4f42626221c88976f2622ff7336086eb01ff7d728c9dd2e4824c25eed` |

The 16 differing bytes occupy exactly the Mach-O section
`__LLVM,__swift_modhash`, at zero-based offset 23,680 with size 16. Every byte
outside that section matches. The retained file sets match, all other retained
objects match, and all nine retained executables match.

The private readback report inventories the retained files, hashes and differing
section bytes. Its SHA-256 is
`05bfecb757258d69904695cbed7b3a67337629b2f98163be6ce52659dba4012d`.

## Assessment and limits

The [pinned upstream Swift implementation](https://github.com/swiftlang/swift/blob/29896a2c70406131e3658d282f718843de66f8bb/lib/IRGen/IRGenModule.cpp#L2341)
identifies this section as an incremental-compilation module hash and states
that the Darwin linker ignores its containing segment. The retained upstream
source file has SHA-256
`ce69e44a4cb2af579db383f5b64de91f7ab26aaadc665a01fb9c428d95f19da6`.
This supports the inference that the observed variance is compiler metadata;
the exact cause in the original Apple toolchain has not been established.

The retained executable bytes demonstrate executable reproducibility for that
historical pair. The object bytes demonstrate that all-object reproducibility
was not achieved. No normalization or stripping was applied to claim equality.

The next candidate requires its own retained build-pair comparison and
corresponding-source, license, SBOM, signature and provenance verification.
Keep this historical variance and any new findings explicit in #275's final
evidence and independent review. This assessment alone does not close #275 or
approve promotion.
