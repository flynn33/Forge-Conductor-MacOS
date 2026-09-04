# B — Finish supported managed-provider configuration

**Problem:** a clean installation cannot create/update the provider configuration through supported product controls. The current view model exposes only status and probes.

## Existing source to inspect

- `Sources/ForgeNativeSessionHostPlugin/ForgeNativeSessionHostPlugin.swift`: `LMStudioProviderConfiguration`, validation, transport, adapter lifecycle and receipt handling.
- `Sources/ForgeConductorApp/OperatorConsole/ViewModels/ProviderViewModel.swift`.
- `Sources/ForgeConductorApp/OperatorConsole/Views/ProviderOperatorView.swift`.
- `Sources/ForgeConductorApp/OperatorConsole/Services/OperatorManagerClient.swift`.
- Corresponding operator models, production dashboard/manager routes, bootstrap and provider-registration code. Discover the actual symbols before editing; no invented endpoint is prescribed here.

## Implement the smallest complete vertical path

Keep configuration ownership in a typed application/manager service, injected through existing protocols. SwiftUI must not directly patch provider files or manipulate Keychain behind the manager. Reuse the existing validated configuration shape and bounds: `lmstudio-provider.json`, 64 KiB file limit, loopback HTTP allowed, non-loopback HTTPS required, no URL credentials/query/fragment. Preserve meaningful timeout and payload ceilings.

Provide native controls for endpoint and model selection/identifier, an optional token entry with Keychain storage, Save, Test Connection, and clearly actionable state/errors. Retrieve available models using the already supported LM Studio transport/version contract, not a guessed endpoint or a new SDK. Distinguish no model, unloaded model, authentication failure, server offline, invalid endpoint, timeout, and successful usable configuration. Saving a valid configuration while the provider is offline must not falsely report a successful connection.

Expose a typed authenticated manager operation for read-redacted/update and connect it to the native client. Add a CLI configuration path only by extending the existing command design, not by directing users to hand-edit JSON. Protect updates with the existing manager authorization model. Use bounded, owner-only atomic persistence and explicit revision/generation handling. Reject malformed values before mutation; retain the last valid configuration on failure.

Tokens never belong in JSON, logs, error messages, screenshots, process arguments, MCP responses or exported evidence. An update of file configuration and Keychain references needs a recoverable ordering: do not delete the last working credential until the new configuration is committed. Clear-token and keep-token must be distinguishable. Test Keychain denied/locked/cancelled and persistence failure. Do not print secret values to prove the test.

Reconfigure the provider through its owner with bounded cancellation and in-flight request handling. A settings view disappearing must not remove the manager's ability to run. The resulting provider must survive GUI closure and manager restart. Preserve lease/receipt/inference-retry semantics; never solve an update race by discarding durable run state.

## Acceptance

From an isolated clean Forge home, use the actual native UI to save endpoint/model and any authorized credential, establish a real connection, start a managed run, close/reopen the GUI, restart the actual manager, and verify persisted configuration and continued usability. Include invalid URL, insecure remote HTTP, missing/invalid credential, invalid model, concurrent updates, cancellation and interrupted persistence tests.

Add unit/manager-route/native-client tests, native UI assertions with accessibility identifiers, and at least one registered production scenario. Update both Xcode and SwiftPM memberships and the relevant provider setup/user guide. No test may provision the JSON file directly and then claim that onboarding works. Do not add model loading/unloading or a separate inference engine to this shipping task.
