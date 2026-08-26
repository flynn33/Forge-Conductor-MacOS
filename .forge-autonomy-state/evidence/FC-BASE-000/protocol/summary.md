# FC-BASE-000 executable MCP protocol baseline

Captured from a debug `forge-conductor` product built from Git commit `1f39ee6bdf1d4f907c6e1cb31f6213f2945d3985` in an isolated evidence scratch tree.

## Result

- `initialize`, `tools/list`, `resources/list`, `prompts/list`, and `ping` all returned successful JSON-RPC 2.0 responses.
- The current executable exposes 53 unique tools. All 34 baseline tool names remain present; no tool was removed.
- Nineteen additive tools are present: seven `continuity.*` tools and twelve `project_memory.*` tools.
- The initialize response keeps server name `forge-conductor` and protocol version `2025-11-25`, changes the server version from `0.8.0` to `0.9.0`, and adds the `projectMemory` capability block.
- Resources remain empty, prompts remain empty, and ping remains an empty result object.
- Common-tool descriptions and relative ordering are unchanged.
- One common input schema differs: `shell_exec.timeout_sec` now advertises `exclusiveMinimum: 0` and `maximum: 120`; the baseline advertised only `type: number`. This is a schema-narrowing delta that needs an explicit compatibility disposition even though the tool name and other fields remain present.

## Added tool names

- `continuity.acknowledge_handoff`
- `continuity.checkpoint`
- `continuity.get_pending_handoff`
- `continuity.prepare_handoff`
- `continuity.request_rollover`
- `continuity.resume`
- `continuity.status`
- `project_memory.export`
- `project_memory.forget`
- `project_memory.get`
- `project_memory.import`
- `project_memory.initialize`
- `project_memory.link`
- `project_memory.list_recent`
- `project_memory.remember`
- `project_memory.remember_batch`
- `project_memory.search`
- `project_memory.status`
- `project_memory.update`

## Primary artifacts

- `responses.ndjson`: raw executable response stream.
- `transcript.json`: request/response pairs, including the initialized notification.
- `current-protocol-inventory.json`: all current tool names, descriptions, and complete input schemas.
- `baseline-comparison.json`: exact initialize, tool, schema, resources, prompts, and ping differences.
- `validation.json`: executable checks and parity assertions.
- `commands.jsonl`: commands, exit codes, timestamps, output paths, and output hashes.
