# Qwen Code driver qualification

The Qwen customization is operational infrastructure. It must pass these tests before it is used on product source.

## Package-level tests

- All Python scripts compile without creating `__pycache__`.
- All shell scripts pass `bash -n`.
- All Qwen schemas pass Draft 2020-12 validation.
- Every P00–P14 work package has exactly one card.
- Every card's gates, findings, dependencies, and source targets match `plans/work-packages.json`.
- Package manifest hashes every non-generated file.
- ZIP paths are relative and traversal-safe.
- Publication and secret scans pass.

## Installer tests

On a clean extraction of the supplied current repository:

- product source manifest is unchanged by installation;
- `.forge-qwen-remediation`, `.forge-qwen-state`, `.forge-continuity-design`, and `.forge-e2` exist;
- root `QWEN.md` and `AGENTS.md` contain one marker block;
- a second installation replaces the marker rather than duplicating it;
- unrelated root instructions and existing Qwen settings survive;
- unrelated `PreToolUse` hooks survive;
- the publication guard is present exactly once;
- no running local provider is required for installation;
- no secret is persisted.

## Provider tests

With a deterministic local fixture server:

- a non-loopback URL is rejected;
- an unavailable endpoint is recorded and skipped;
- a wrong model is rejected;
- Qwen3.8-27B without quantization metadata is rejected in strict mode;
- a Q4 model is accepted;
- explicit unverified-quantization override is recorded;
- optional thinking-field rejection downgrades to a successful base probe;
- base completion failure blocks preflight;
- provider settings contain a complete atomic generation configuration;
- the model ID used by Qwen Code exactly matches the discovered provider ID.

## Guard tests

The hook must allow:

```text
swift test
xcodebuild test
git status
git diff
git commit
codesign local ad-hoc test artifacts
```

It must reject:

```text
git push
git tag
gh pr create
gh pr merge
gh release create
npm publish
swift package-registry publish
xcrun notarytool submit
scp artifact remote:
git reset --hard
git clean -fdx
rm -rf /
```

## Structured-output tests

Fixtures must cover:

- direct JSON object;
- Qwen JSON array with a terminal result message;
- structured output embedded as a string;
- malformed JSON;
- schema-invalid result;
- empty stdout;
- nonzero exit with partial JSON;
- attempted `claims_gate_passed=true`.

The finalizer preserves raw files in every case and never accepts a gate.

## No-progress tests

- A handoff-only update does not count as progress.
- A timestamp-only state update does not count as progress.
- A source-manifest change counts.
- An accepted gate receipt counts.
- A finding closure counts.
- Three no-progress invocations discard the plan and force re-planning.
- The bounded invocation cap stops with resumable state rather than looping forever.

## Live smoke test

With the exact local model loaded:

1. preflight verifies flags, model, quantization, and structured output;
2. plan mode reads one fixture task without modifying files;
3. implementation mode changes one temporary fixture and runs one focused test;
4. finalizer records raw and normalized output;
5. handoff is updated;
6. review runs read-only;
7. publication guard rejects a deliberately attempted benign fixture `git push --dry-run` before execution;
8. no remote side effect occurs.

A live smoke test is operational evidence for the Qwen driver only. It is not a Forge Conductor product release gate.

