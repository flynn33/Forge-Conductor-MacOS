# Handoff Format

The canonical JSON schema is `schemas/handoff.schema.json`.

## Required semantic sections

- identity and schema;
- mission;
- project/repository state;
- current work;
- completed work;
- open work;
- decisions;
- validation state;
- memory and evidence references;
- next actions;
- host/provider state;
- integrity metadata.

## Quality requirements

A handoff must be:

- sufficient for a clean session to resume without asking what happened;
- compact enough to stay below the configured handoff budget;
- explicit about facts versus hypotheses;
- explicit about failed attempts;
- reference-oriented rather than a raw transcript;
- reproducible through commands and artifact hashes;
- free of credentials and prohibited content.

## Handoff generation

Generate from structured run state and project memory, not solely from free-form model recollection. Validate against schema, write atomically, insert into the memory repository, and then make it discoverable to the successor.

## Resume behavior

The successor:

1. validates checksum/schema;
2. confirms project and repository identity;
3. loads referenced decisions, issues, and evidence on demand;
4. verifies Git/build state;
5. acknowledges the handoff;
6. executes the first ready next action;
7. records deviations.

## Size policy

Use byte limits from the resource policy. If content exceeds the limit:

- retain mission, constraints, active state, failures, and next actions;
- replace detailed completed history with memory references;
- retain hashes and commands;
- never truncate JSON blindly.
