# FC-UI-001 decision and change summary

The native operator console implementation is present, but this work package is not
passed. Three XCUITest invocations produced durable non-pass evidence. The unsigned
runner was killed before it established a UI-testing connection. The normal signed
build could not find a Mac Development identity for configured team `2Y25RTLZET`.
The ad-hoc-signed runner built and launched far enough to initialize XCTest, then timed
out while enabling automation mode.

A current host-prerequisite check confirms that Developer mode is disabled. The host has
other code-signing identities, but none matches the team required by this project. These
are external host-authorization and signing blockers; no product behavior is inferred
from the failed runner initialization.

The accessibility, reconnect-without-duplicate-scheduler, state/error presentation, and
credential-display acceptance criteria therefore remain unverified. Re-run the same
XCUITest flow after Developer mode is enabled and the configured team's signing identity
is installed. Do not mark this work package passed from build-only evidence.
