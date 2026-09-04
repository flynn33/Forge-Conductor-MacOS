# Instruction-package validation summary

This package is a self-contained remediation input customized for Qwen Code with a locally served Qwen3.8-27B 4-bit model. It is **not** a claim that the included Forge Conductor application has already been repaired or release-qualified.

Validated package properties include:

- every required architecture, audit, plan, schema, script, Qwen profile, work-package card, test, template, input, and evidence artifact is present;
- all input hashes and ZIP CRCs match;
- the supplied current repository regenerates the recorded source manifest;
- all thirty audit findings are represented in the initial state, finding mapping, and blocker matrix;
- all fifteen work packages form an acyclic dependency graph;
- all twenty-one gates have fixed validator identities, versions, prerequisites, pass criteria, and forbidden substitutes;
- JSON and Draft 2020-12 schemas parse, including the three Qwen structured-output schemas;
- control-plane and retention SQL execute against a validation fixture;
- Python and shell scripts pass syntax checks and required scripts are executable;
- the Qwen pre-tool hook permits local build/test commands and denies push, PR, release, upload, destructive reset, and shipping commands;
- the Qwen settings merger preserves unrelated settings and hooks while installing exactly one required guard;
- the Qwen driver uses fresh sessions, bounded turns/tools/wall time, schema output, a fixed model, and `--exclude-tools agent`;
- no opaque `--continue` or chat-resume path is used as durable authority;
- publication-hygiene and secret scans pass;
- the package manifest matches every included file;
- a clean temporary repository install succeeds and is idempotent;
- remediation, state, continuity, E2, and project-local Qwen settings install correctly;
- installation does not alter the Forge Conductor product source manifest;
- the selector resumes at P00;
- direct gate passing and premature work-package completion are rejected;
- completion verification fails on the untouched repository rather than claiming success.

Provider-dependent Qwen smoke testing is intentionally a target-host preflight, because the package does not bundle or download a model. Native macOS/Xcode, signing, LaunchAgent, UI, Instruments, real-provider rollover, E2, XPC, low-memory, endurance, and integrated autonomy gates remain implementation requirements.

The terminal product state is:

```json
{
  "ready_to_ship": true,
  "shipped": false
}
```
