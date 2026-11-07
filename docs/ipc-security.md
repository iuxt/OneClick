# IPC authentication

OneClick and its Finder extension communicate over a local UNIX-domain stream.
They do not store or read a communication key, and do not use the login Keychain.

Each side obtains its peer's audit token from the connected socket using
`LOCAL_PEERTOKEN`. It uses `SecCodeCopyGuestWithAttributes` to identify that live
process, then `SecCodeCheckValidity` to check it against the installed
counterpart's designated code requirement. A claimed bundle identifier, user ID,
PID supplied by a message, or knowledge of the socket path is insufficient.
Validation happens before reading or dispatching any payload. The audit token
binds the check to the actual peer rather than a potentially reused process ID.

The host accepts the bundled Finder extension's requirement. The extension
accepts its containing application's requirement. This also supports ad-hoc
local builds: their code requirements identify the installed code rather than a
public shared secret. Updating the app requires restarting both processes so
neither continues using requirements from the previous build.

The host maintains a connection to each Finder extension process and broadcasts
configuration/liveness updates to all of them. Extensions reconnect after a host
restart and request current configuration. Blocking reads and writes run on
background queues, writes have a timeout, and frame sizes are bounded to 4 MiB.
Messages carry a version, direction, action, ID, creation time and payload in one
frame. Receivers reject the wrong direction/version, messages older than 60
seconds, messages more than five seconds in the future, and replayed IDs.

For provisioned builds the socket lives in the App Group container. Apple's
[App Groups entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)
describes UNIX-domain IPC within that container. Normal target entitlements need
no extra networking permissions for this arrangement.

The host runs without App Sandbox. Finder Sync extensions must remain sandboxed
for macOS to load them. Local (`RC_LOCAL_BUILD`) builds keep the existing
`Library/Application Support/RClickLocal` directory and socket location.
`scripts/local-entitlements.py` grants only the extension file access to this
directory and outbound access to the exact `ipc.sock` path. The host needs no
sandbox exception to bind or connect. The rule uses `home-literal`, so release
artifacts never embed the CI runner's home path. Provisioned extension builds
continue using their App Group. The socket is mode 0600; removing the host's
sandbox does not change peer code validation, replay checks or protocol limits.

Protocol v3 does not register DistributedNotificationCenter observers. Legacy
notifications, public fixed-key signatures, and old Keychain-backed envelopes
cannot invoke actions. An existing old Keychain item is left untouched; the new
version never reads, replaces or deletes it.

`IPCTransportTests` verifies multi-extension delivery, large frame boundaries,
host restart/reconnection, rejection before dispatch and preservation of a
pre-existing regular file at the endpoint path. `IPCEnvelopeTests` verifies
freshness, direction, replay and legacy-envelope rejection. A separate real
mixed-process, ad-hoc-signed integration harness (`python3 scripts/test-local-ipc.py`)
uses the production transport and entitlement generator to exercise bidirectional
code validation between a non-sandboxed host and a sandboxed extension. It uses
disposable bundles and a separate socket directory, and never launches the
installed app or accesses its settings. The release workflow runs this check
before building the artifact.
