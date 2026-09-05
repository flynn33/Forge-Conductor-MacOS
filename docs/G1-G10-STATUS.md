# Historical G1–G10 status (0.9.0)

This table preserves the product-status snapshot recorded for the historical
0.9.0 build 1 baseline. Its G1–G10 labels predate the package qualification
ledger and do not qualify the active source tree. That ledger retains its own
still-open evidence in
[`../.forge-codex/state/release-handoff.md`](../.forge-codex/state/release-handoff.md),
but current source, the user guide, and the changelog define product behavior.

Legend: **CODE** = implemented in the historical Xcode project · **TEST** =
exact historical automated proof · **OPS** = operator-owned follow-up

| ID | Requirement | CODE | TEST | OPS |
|----|-------------|------|------|-----|
| G1 | Deploy product path (Deploy → plugins → use) | Yes | Transactional config + standalone smoke + LM Studio host acknowledgement | Load a model |
| G2 | Main + failover plugins | Yes | Installer writes and host-verifies both under one revision | None |
| G3 | Native Apple build and operator verification | Yes, SwiftPM + Xcode project | Historical evidence: 269 unit/integration tests + 5 native UI tests; not current-source authority | **You sign/release** |
| G4 | Modular OOP | Yes (typed services/protocols/clients/tool packs) | Protocols + services compile/test | Maintain boundaries |
| G5 | Real-time host telemetry (not 2s snapshot) | Yes (~30 Hz stream + continuous SSE + GUI bind) | RealtimeStreamTests multi-frame | Optional RIG look |
| G6 | Diagnostics + JSON/MD export | Yes + rotation + more events | Export unit test | **You** export after use |
| G7 | Reliable MCP tools/agents | Protocol negotiate + tools surface + host activation | In-process handshake + LM Studio-originated tools/list | Model-use acceptance |
| G8 | Single product / no dual port fight | **Yes: manager owns bind; GUI attaches; second manager fails closed** | Port guard + loopback client integration | None for normal launch |
| G9 | Installable single product identity | Prefer running app for Deploy; install still multi-path | Resolve + smoke | **You** install one app |
| G10 | No fake “done” without evidence | This historical matrix; Deploy fails if smoke fails | Completion gates and indexed evidence expose pass/fail state | Operator acceptance |

## Current qualification boundary

The historical table above is unchanged. Current retained local/CI results and
source scopes are summarized in [qualification status](QUALIFICATION-STATUS.md).
The local app-hosted suite and four separate native onboarding scenarios passed,
including provider save/discovery and Settings shell off/on with fresh MCP
processes. Subsequent Swift Debug/Release CI failed one Python containment test
with three assertion failures per lane. These are recorded results, not tests
rerun for this documentation.

The installed-app qualifier passed bounded raw-CLI, shell, migration, and
app/manager restart checks. It remains partial because its own System Events
Settings step was not run; the separate native Settings case passed. Only the
two canonical CLI version/help assertions have been accepted in development
installed Release scope; the other 257 assertions in the 104-feature P10 matrix
remain unqualified.

The earlier 100-cycle Rig/MCP navigation result is historical supporting
evidence. Later native Release gauge component tests passed 100 lifecycle
cycles and resource assertions, while closed fixture windows accumulated to
101. Whole-app window/leak closure, the complete installed/native
UI/settings/service-lifecycle matrix, Developer ID Release and
archive/notarization/Gatekeeper, manager-owned real-provider autonomous
continuity, owner-deferred representative physical-hardware qualification,
current G09-G12, and release qualification remain open. Historical or focused
unit, UI, simulator, synthetic-host, or direct-adapter results do not replace
that authority. Filesystem capture and quarantine remain mitigation until the
signed E2 matrix and formal closure pass.

## Port ownership behavior

1. `DashboardPortGuard` — detects who holds :7788  
2. `DashboardServer.start` **waits for bind ready/failed** (no silent “listening” on conflict)  
3. A second manager **fails with a clear error** instead of lying in manager state  
4. The GUI detects and attaches to an existing LaunchAgent manager without binding again  
5. The GUI retries transient manager connection loss and logs attach/recovery state  
6. Deploy smoke-tests `serve`, revisions all required LM Studio configuration, activates the host, and requires both hosted tool lists  

## What is still NOT claimed

- Model-specific tool-selection quality inside a conversation  
- Automatic killing of a foreign process that owns the configured port (unsafe without your OK)  
- Hub marketplace card named “Forge-Conductor”  
