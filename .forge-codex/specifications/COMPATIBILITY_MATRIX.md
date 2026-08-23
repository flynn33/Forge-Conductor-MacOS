# Compatibility Matrix

Codex must replace discovery placeholders with the exact repository baseline.

| Surface | Baseline source | Preservation mechanism |
|---|---|---|
| macOS deployment target | Xcode/Package settings | build matrix |
| CPU architectures | build settings | architecture builds |
| App scenes/windows | SwiftUI/AppKit discovery + runtime | UI/semantic tests |
| Commands/shortcuts | command declarations | command tests |
| Settings/defaults | UserDefaults/AppStorage keys | fixture migration |
| Project formats | readers/writers | round-trip fixtures |
| Existing MCP tools | initialize/list-tools transcripts | golden protocol tests |
| MCP transport | server startup/config | transport integration |
| Model/provider clients | adapters/config | fake + configured integration |
| Telemetry metrics | types/mappings | mapping tests |
| Gauge identities/units | UI and telemetry definitions | semantic rendering tests |
| Process integrations | service declarations | lifecycle tests |
| Memory/continuity tools | existing surfaces | additive aliases/versioning |
| Import/export | formats and actions | round-trip tests |
| Accessibility | identifiers/tree | UI tests |

## Host capability modes

### Mode A — external MCP client

The external client invokes memory and continuity tools. Forge can prepare and expose handoffs. Automatic creation of a new external chat is enabled only when that host exposes a supported adapter API.

### Mode B — Forge-native session host

Forge owns logical model sessions and provider requests through the native host plugin. Full automatic rollover is mandatory.

### Mode C — supported external host adapter

A documented host API provides session creation/bootstrap/acknowledgment. Full automatic rollover is mandatory when configured.

All modes share the same project memory and handoff repository.
