# Phase 13 Docker socket and context security

The Docker proxy is local-only. It binds a Unix-domain socket below a private
`0700` directory and sets the socket to exact mode `0600`. Every accepted
connection is checked with `getpeereid`; a peer whose effective user differs
from the proxy's effective user is rejected before HTTP parsing.

The listener validates every directory component with `lstat`, rejects
symlinked parents and unsafe modes, and pins both the parent-directory and
socket `(device, inode)` identities. Before accepting a request it rechecks
those identities and the socket type, owner, and mode. Cleanup unlinks only
the exact socket inode created by that listener. Stale recovery is limited to
an owned `0600` socket that refuses a connection; a live socket, an unsafe
socket, or an identity race is left untouched and rejected.

Docker contexts are bounded JSON documents below an owned private `0700`
directory. Context files and the active marker are owned private regular files
with mode `0600`, one link, bounded size, and validated names/absolute socket
paths. Writes use a unique bounded temporary file and an atomic rename. Reads
of the active marker use `O_NOFOLLOW` and descriptor metadata validation.

The Docker socket's peer check is the local admission boundary. Requests that
need data still cross the authenticated Phase 09 `PersistentControlClient`
boundary; the Docker module has no runtime, state, or direct filesystem
authority. There is no TCP listener, public exposure, Docker Desktop
mutation, or credential material in argv, context documents, or protocol
errors.
