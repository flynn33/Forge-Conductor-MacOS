# Autonomous native prerequisite handling

Qwen Code must discover and prepare the local macOS qualification environment without asking the operator to choose implementation details. It may not convert a missing prerequisite into a passing gate.

## Required discovery

Record exact versions and paths for macOS, architecture, Xcode, Swift, SDKs, command-line tools, Git, codesign, security identities, `xctrace`, LM Studio/`lms`, Python, PowerShell, and available local filesystems. Record Developer Mode and UI-test readiness when observable without prompting.

## Local signing

Distribution credentials are not required for this mission. For local signed tests, prefer an existing development identity. Otherwise use `create_ephemeral_codesign_identity.sh`, add the temporary keychain only to the test command’s search list, and delete it with the cleanup script. Never commit or preserve the private key, P12 password, keychain password, or expanded environment file.

## LM Studio

Use the existing configured local provider first. Discover server health, loaded models, context capacity, API compatibility, and MCP/tool behavior through bounded probes. If the provider is installed but no model is loaded, use its supported local CLI/API to select an already installed compatible model. Downloading a large model is allowed only when the environment policy permits network and disk use; record the exact model identity and hash/metadata. Never replace the real-provider release gate with a fixture.

A deterministic fixture server remains mandatory for fault injection, replay, malformed streams, disconnects, duplicate roots, delayed acknowledgment, and crash recovery. It supplements rather than substitutes for the real-provider gate.

## PowerShell and Python

Python is an external runtime, not Forge’s implementation language. Detect the configured interpreter and test isolated invocation. PowerShell is optional at runtime; a missing executable must produce accurate capability status without disabling Bash, native shell, direct process, or legacy `shell_exec`. When qualification requires PowerShell and the host permits dependency installation, use a supported package source and record version/provenance. Do not silently install dependencies from model-generated scripts.

## XPC and App Sandbox

Build and sign the XPC helper and host together with a matching local team identity. Verify entitlements from the built products rather than trusting project settings. Test security-scoped bookmark acquisition, balance, stale recovery, and release. Use explicit no-network and allowed-network profiles; absence of a network entitlement is not by itself proof that descendants cannot communicate.

## Developer Mode or host restrictions

Attempt only documented, reversible, noninteractive preparation supported by the host. Do not weaken SIP, Gatekeeper, sandbox entitlements, test assertions, or production security to make a gate run. When an OS-level privilege cannot be obtained in the current process, record the exact blocked prerequisite and continue independent work. The final release-ready state remains unavailable until the gate is actually executed on a suitable macOS host.

## Resource qualification hosts

Prefer direct execution on representative machines. When physical 8 GiB hardware is unavailable, use enforced process/resource pressure and deterministic allocations as a development signal, but do not call it equivalent to an actual constrained-machine release gate unless the gate definition explicitly permits that method. Keep raw traces and machine specifications in evidence.
