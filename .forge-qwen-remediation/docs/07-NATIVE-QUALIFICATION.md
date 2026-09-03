# Native macOS qualification

## Build and execution authority

Run both SwiftPM and Xcode. Xcode is authoritative for app, UI, XPC, signing, entitlements, LaunchAgent, Keychain, AppKit, SwiftUI, and Metal behavior.

## Signing without operator intervention

When no suitable development identity exists, create an ephemeral local code-signing identity and temporary keychain using the supplied script. Use it only for local tests. Never store its key or password in the repository or evidence bundle.

## Required native suites

- executed signed XCUITest, not build-for-testing;
- LaunchAgent install/start/restart/reconnect;
- Keychain credential create/read/delete and locked/unavailable paths;
- Settings-to-manager-to-MCP shell flow;
- provider probe and real LM Studio run;
- threshold-forced fresh-root rollover with GUI closed;
- XPC allow/deny/network/cancellation tests;
- E2 atomic swap tests;
- Address Sanitizer and Thread Sanitizer separately;
- Allocations, Leaks, Time Profiler, SwiftUI, and Metal System Trace;
- constrained-memory and endurance scenarios.

## Native gate status

A missing model, runtime, signing identity, or installed provider is a blocked environment prerequisite. Qwen Code must install or create test infrastructure when permitted and continue independent work. It must never record the gate as passed without execution.
