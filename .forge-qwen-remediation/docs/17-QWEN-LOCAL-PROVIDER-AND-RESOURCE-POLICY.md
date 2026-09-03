# Qwen local provider and resource policy

## Supported provider contract

Qwen Code is configured through an OpenAI-compatible provider entry. The remediation package accepts only HTTP loopback endpoints:

```text
127.0.0.1
localhost
::1
```

No remote provider fallback is allowed. Credentials are read from `FORGE_QWEN_LOCAL_API_KEY`; a local server may use the placeholder value `local-only`.

The configuration script queries `/v1/models`, selects an exact Qwen3.8-27B candidate, and records the complete provider response used for the decision.

## Quantization proof

The selected model must be a 4-bit artifact. Acceptable provider metadata may identify:

```text
Q4
Q4_K_M
4-bit
INT4
W4A*
AWQ
MLX 4-bit
```

A model name that says only Qwen3.8-27B is not quantization proof. When the provider omits quantization metadata, the strict preflight stops. After independently verifying the loaded artifact, the environment may set:

```bash
QWEN_ACCEPT_UNVERIFIED_QUANTIZATION=1
```

The profile records that as an explicit downgrade. The override does not become release evidence.

## Provider probe

Before autonomous work:

1. query `/v1/models`;
2. validate the exact model and quantization;
3. send a minimal completion with optional thinking/reasoning fields;
4. if the provider rejects only the optional fields, repeat without them;
5. reject the provider if the base completion fails;
6. run a Qwen Code headless structured-output smoke test.

No product edit occurs before this preflight succeeds.

## Host-memory profiles

The profile is intentionally below the model's maximum native context:

| Physical memory | Context | Max output | Top-level tools | Session turns |
|---|---:|---:|---:|---:|
| under 24 GiB | 16,384 | 4,096 | 14 | 12 |
| 24–31 GiB | 32,768 | 6,144 | 18 | 15 |
| 32–63 GiB | 65,536 | 8,192 | 24 | 18 |
| 64 GiB or more | 98,304 | 12,288 | 32 | 22 |

Environment overrides are allowed only within the bounds enforced by `configure_qwen_local.py`.

These values budget for:

- quantized model weights;
- KV cache;
- runtime and Metal buffers;
- Xcode/Swift compiler memory;
- Forge Conductor and manager processes;
- Instruments or test runners;
- filesystem cache and normal macOS operation.

A larger context is not automatically more efficient or reliable. Increase it only after measuring end-to-end throughput, memory pressure, and quality on the target host.

## Sampling

The default reasoning profile uses:

```text
temperature: 1.0
top_p: 0.95
top_k: 20
presence_penalty: 0.0
```

Provider-specific thinking fields are included only when a probe proves they are accepted. The provider configuration is emitted as one complete generation configuration because provider-level generation settings are treated as an atomic entry.

## Qwen Code settings

The installer preserves unrelated user settings while enforcing project-local remediation controls:

- OpenAI-compatible provider selected for this repository;
- bounded model/session settings;
- `approvalMode: yolo` for the implementation driver;
- managed auto-memory disabled;
- auto-dream disabled;
- auto-skill disabled;
- team-memory and synchronization disabled;
- usage statistics disabled;
- review attribution disabled;
- chat recording enabled for local recovery;
- no-sleep enabled during bounded work;
- publication guard installed as a `PreToolUse` command hook.

Existing unrelated hooks are preserved. The required guard is replaced by name rather than duplicated.

## Resource behavior

The autonomous driver itself is bounded:

- one Qwen process at a time;
- no subagent fan-out;
- bounded raw logs per invocation;
- bounded session turns, wall time, and top-level tool calls;
- no implicit continuation of a long chat;
- no parallel compile/test jobs unless the selected work package explicitly permits them;
- no automatic model download or runtime installation without opt-in.

The product's own resource budgets in `plans/resource-budgets.json` remain mandatory and independent of the model-runner budget.

