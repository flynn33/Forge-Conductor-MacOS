# Repository Installation Behavior

The package does not overwrite an existing repository instruction file without preserving it.

`install_into_repo.sh`:

- copies the package runtime into `.forge-codex`;
- prepends the Forge execution contract to root `AGENTS.md`;
- backs up a pre-existing `AGENTS.md`;
- installs repository-scoped skills into `.agents/skills`;
- creates `script/build_and_run.sh` only when absent;
- initializes state, gate/flow handler directories, baseline templates, and evidence storage;
- preserves product source.

The installer is idempotent. Re-running it refreshes package documents and scripts while retaining `.forge-codex/state` and evidence.

## Files Codex may edit

Codex may edit:

- product source and tests required by the phases;
- project/Package manifests;
- `script/build_and_run.sh`;
- `.forge-codex/state`;
- phase-specific gate/flow handlers;
- architecture decisions and completion evidence.

Codex must not edit the immutable copies under `.forge-codex/audit` to resolve findings.

## Generated state excluded from release source

Large traces, memgraphs, derived data, and temporary databases should be outside normal source control. Keep small reports, schemas, migrations, tests, and required fixtures under repository conventions. Add ignore entries carefully without hiding existing tracked artifacts.
