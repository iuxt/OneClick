# Automatic input method switching

Open **Toolbox → Input Method Switching**, enable **Automatically switch input
methods**, then add an application and select an enabled macOS input source.
Rules use the application's bundle identifier and survive moving the app.

Priority is an explicit application rule, a remembered input source (when
enabled), then the default. **Keep Current Input Method** leaves unconfigured
apps alone. Manual changes remain in effect until the next app activation.
Settings and remembered choices persist in shared preferences.

The service starts with OneClick even when its settings window is closed. It
watches workspace activations and system input-source notifications, cancels
stale switches, checks results, and retries at most three times. It respects
secure event input, including password fields. Enable missing input sources in
macOS System Settings, then use **Refresh Input Methods**.

This integration covers app rules, a default and remembered input methods.
LockIME's website rules, floating overlays, shortcuts and continuous locking
are outside this integration.

## Upstream attribution

The Carbon Text Input Services adapter in
`OneClick/Runtime/InputMethodService.swift` is adapted from
[oomol-lab/LockIME](https://github.com/oomol-lab/LockIME), specifically
`Sources/LockIMEKit/LockEngine/TISInputSourceProvider.swift` and the conditional
`FocusNudge.swift` fallback for CJK input methods, inspected at commit
`89f2cb258e5f83949d5f0e33561a91a353a26230`. Its activation monitor and bounded
switching logic informed the integration. Copyright remains with the LockIME
contributors. LockIME and OneClick use GNU GPL version 3; the license is included
in the root `LICENSE`. The settings page links to the upstream project.
