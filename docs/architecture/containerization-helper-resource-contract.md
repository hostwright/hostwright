# Containerization helper resource allocation

The Containerization 0.35.0 create payload carries `cpuCount` (integer cores)
and `memoryBytes` (unsigned bytes) copied from the desired runtime service.
Both must be explicit and positive. CPU values must fit the SDK's signed
100,000-microsecond cgroup quota calculation; memory must fit its signed
cgroup limit. The adapter, authenticated helper dispatcher, and backend reject
missing or invalid limits before creating or persisting a resource. These
checks do not replace host capacity admission.

Both fresh-rootfs creation and stopped-rootfs restoration assign the limits to
`LinuxContainer.Configuration.cpus` and `.memoryInBytes`. The SDK applies these
values to workload cgroup quotas; its separate VM CPU and memory overheads
remain SDK configuration values. Inventory uses `LinuxContainer.cpus` and
`.memoryInBytes` when a container exists. Create, start, and restart must read
back the exact desired allocation before returning a verified result.

The persisted record stores the limits and an allocation verification flag.
After helper recovery, stopped inventory can report this previously verified
configuration. A running resource without SDK readback has no allocation
evidence. Legacy records without limits remain available for exact owned
cleanup, report no allocation, and reject start/restart until recreated.
Malformed stored allocations fail record validation rather than gaining SDK
defaults. A failed readback never sets the verification flag.
