# Security Policy

## Supported Versions

We release patches for security vulnerabilities in the following versions:

| Version | Supported          |
|---------|--------------------|
| 2.0.x   | :white_check_mark: |
| 1.7.x   | :white_check_mark: |
| < 1.7   | :x:                |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, please report them via email to the project maintainers. We will respond as quickly as possible to acknowledge receipt and coordinate a fix.

### What to Include

When reporting a vulnerability, please include:

- **Description** — What is the vulnerability and what is its potential impact?
- **Steps to Reproduce** — A step-by-step guide, including specific macOS version and RClick version.
- **Affected Components** — Which part of the app is vulnerable? (Main app, FinderSync Extension, IPC layer)
- **Proof of Concept** — If possible, code or steps that demonstrate the issue.

### Response Timeline

- **Acknowledgment**: Within 48 hours
- **Assessment**: Within 5 business days
- **Fix Release**: Depending on severity; critical issues will be patched as quickly as possible

### Disclosure Policy

We follow a coordinated disclosure process:

1. Reporter submits vulnerability via email.
2. We acknowledge and assess within 48 hours.
3. We develop and test a fix.
4. We release the patched version.
5. After the patch is released, we may publish a security advisory (CVE if applicable) crediting the reporter (if desired).

## Security Considerations for RClick

As a macOS Finder extension, RClick has these security-sensitive areas:

- **File System Access** — RClick is sandboxed and uses security-scoped bookmarks for per-folder authorization: file operations check `PermissionService.hasAccess(to:)`; un-authorized folders trigger a one-time `NSOpenPanel` grant that is cached as a bookmark. Full Disk Access is not used.
- **Inter-Process Communication** — The main app and Finder extension use a local stream with mutual code-signature checks against the kernel-provided peer audit token. No communication keys or Keychain access are required. Versioned frames reject stale and replayed messages. See [IPC authentication](docs/ipc-security.md).
- **Third-Party App Launching** — RClick can launch external applications with custom arguments. Arguments are properly escaped to prevent injection.

## Responsible Disclosure Hall of Fame

We appreciate the security research community. Researchers who report valid vulnerabilities will be acknowledged here (with their permission).

---

This policy is adapted from the [GitHub Security Policy template](https://docs.github.com/en/code-security).
