# Signed native UI qualification

Execute tests, do not merely build them.

## Required screens and actions

- Projects: select, relink, reset modes, receipts, generation.
- Work Queue: import, reorder, inspect, pause/resume/retry/cancel.
- Runtimes: capabilities, isolation profiles, cancel job, shell policy.
- Continuity: context gauge, checkpoint, early rollover, timeline.
- Provider: connection test, contract probe, model/context/health.
- Evidence: gate and operation receipts.

## Required lifecycle

- app launch and activation;
- manager LaunchAgent install/start/restart;
- GUI close while manager continues work;
- GUI reopen and event cursor resume;
- no duplicate scheduler or provider loop;
- settings persist;
- shell remains enabled by default;
- VoiceOver labels/accessibility identifiers remain stable.

Use an ephemeral local signing identity if necessary. Record actual executed test counts and result bundle hashes.
