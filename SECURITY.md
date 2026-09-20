# Security Policy

## Supported Versions

Security updates are provided for the latest release of this project.

| Version | Supported          |
| ------- | ------------------ |
| latest  | :white_check_mark: |
| older   | :x:                |

## Local control-plane boundary

The dashboard binds only to loopback and rejects non-loopback Host values.
State-changing requests require same-origin JSON plus route authorization.
Native Manager clients use the owner-only bearer stored in
`manager-control.secret`. The browser control page receives a separate random
per-server capability limited to its visible Manager controls and session
prune/close; it never receives the durable bearer. Privileged shell and
filesystem tools are not exposed as dashboard HTTP routes.

## Reporting a Vulnerability

Please do **not** report security vulnerabilities through public GitHub issues.

### Preferred: private vulnerability report

If private vulnerability reporting is enabled for this repository, use GitHub’s
**Security** tab → **Report a vulnerability**, or open a private advisory from
the repository’s Security page.

### Alternative: email

You may also email **[contact@ravenforgesoftware.com](mailto:contact@ravenforgesoftware.com)** with the subject line:

`[SECURITY] <repository-name>`

### What to include

Please include as much of the following as you can:

* A description of the vulnerability
* Steps to reproduce the issue
* Potential impact
* Affected versions (if known)
* Any suggested fix (optional)

## What to expect

* We will acknowledge receipt of your report as soon as possible.
* We will investigate and keep you informed of progress.
* Once a fix is available, we will coordinate disclosure as appropriate.
* Please give us a reasonable time to address the issue before any public disclosure.

Thank you for helping keep this project and its users safe.
