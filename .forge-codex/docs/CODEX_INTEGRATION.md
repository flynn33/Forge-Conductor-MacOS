# Codex Integration

## Instruction discovery

The installer places the complete execution contract in the repository root `AGENTS.md`. That file is the only Codex-specific discovery mechanism required for correctness.

Repository-scoped skill files are also installed under `.agents/skills` as focused routing aids. They are supplemental: if the active Codex host does not load repository skills, the root contract and `.forge-codex` documents still contain every requirement.

## Start modes

### Interactive Codex workspace

Open the installed repository as the workspace. Codex reads `AGENTS.md`, initializes/resumes state, and executes the phases without asking for technical decisions.

### Headless CLI

Run the optional bounded driver:

```bash
./.forge-codex/scripts/run_codex_autonomously.sh /absolute/path/to/repository
```

The driver probes `codex exec --help` and uses only flags advertised by the installed CLI. It does not assume one fixed CLI release.

### Successor invocation

Every successor invocation receives:

- root instructions;
- persistent run ledger;
- current handoff;
- Git state;
- evidence and decision references;
- next ready phase.

No prior hidden conversation state is required.

## Nested-agent restraint

Do not spawn parallel agents that edit overlapping files or share a mutable build directory. Parallel analysis is allowed when outputs are isolated and merged through the run ledger. One coordinator owns phase/gate state.

## Context safety

Checkpoint after:

- a completed source edit;
- a test/profiling run;
- a material decision;
- a failed approach;
- a phase/gate transition.

Generate the current handoff before ending an invocation. A successor verifies the repository and evidence rather than trusting narrative memory.
