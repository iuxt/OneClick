# IPC authentication

RClick and its Finder extension exchange notifications through
`DistributedNotificationCenter`. Notification names and message metadata are
public; they do not establish sender identity.

Protocol v2 authenticates a single serialized envelope with HMAC-SHA256. The
signature covers the payload bytes, direction, action, outer message ID, protocol
version and creation time. Receivers only decode execution data from those
verified bytes. Messages older than 60 seconds, more than five seconds in the
future, or already processed are rejected. The replay cache is bounded and fails
closed when full. Even payload-free heartbeat, configuration request, quit and
acknowledgement messages require authentication.

Developer-signed and App Store builds generate a random 256-bit credential in
the data-protection Keychain, shared through the existing
`group.cn.wflixu.RClick` App Group. Concurrent initial creation uses the credential
that successfully reached the Keychain. Access failures stop authentication;
there is no constant-key or plaintext-file fallback. Apple documents the existing
App Group entitlement's Keychain sharing behavior in
[Sharing access to keychain items among a collection of apps](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps).

Local (`RC_LOCAL_BUILD`) ad-hoc builds cannot use a provisioned App Group. The
host instead creates a new random session credential on each launch and stores
it in the macOS login Keychain with an explicit trusted-application ACL for the
host and its bundled Finder extension. The host never loads an existing local
credential, avoiding acceptance of a pre-planted key. Finder reads the credential
for each message so a host restart rotates the session without restarting Finder.
macOS can ask for Keychain authorization after rebuilding locally signed apps.
Denied authorization stops communication.

Both processes must be updated together: protocol v1's public fixed key and
unsigned control messages are deliberately rejected. The local installer stops
and re-registers the old extension when replacing the app. Do not restore legacy
message acceptance to work around an extension that has not restarted.

`MessageSecurityTests` uses injected, in-memory credentials and directly invokes
transport handlers. It verifies payload substitution, tampering, wrong keys,
context/ID substitution, replay, expiry, unsigned control messages and legacy-key
rejection without accessing the user's Keychain or posting real notifications.
Actual shared-Keychain access still requires signed app/extension integration
testing with valid provisioning; unsigned unit-test hosts cannot validate it.
