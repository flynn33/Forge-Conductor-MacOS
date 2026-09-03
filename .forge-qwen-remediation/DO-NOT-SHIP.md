# Release boundary

The requested endpoint is **shippable, not shipped**.

## Permitted

- local branches and commits;
- local Debug and Release builds;
- local test signing and hardened-runtime qualification;
- local XCUITest, LaunchAgent, XPC, Keychain, LM Studio, shell, crash, and Instruments runs;
- a private local release-candidate archive;
- SBOM, checksums, release notes, migration notes, and readiness attestation.

## Prohibited

- merging the remediation branch into a release branch;
- creating or pushing a release tag;
- creating a GitHub release;
- uploading an artifact to any public or customer-facing location;
- App Store, TestFlight, package-manager, update-feed, or notarized distribution publication;
- changing a production update endpoint;
- announcing release availability;
- setting `shipped=true`.

The final state must say `ready_to_ship=true` and `shipped=false`.
