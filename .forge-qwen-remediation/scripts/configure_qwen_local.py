#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}
DEFAULT_ENDPOINTS = (
    "http://127.0.0.1:1234/v1",
    "http://127.0.0.1:8080/v1",
    "http://127.0.0.1:8000/v1",
    "http://127.0.0.1:30000/v1",
)
MODEL_RE = re.compile(r"qwen[^/]*3[._-]?8.*27b|qwen3[._-]?8[^/]*27b", re.I)
QUANT_RE = re.compile(
    r"(?:^|[-_./ ])(?:q4(?:_[a-z0-9]+)?|4[-_ ]?bit|int4|w4a\d+|awq|mlx[-_ ]?4bit)(?:$|[-_./ ])",
    re.I,
)

def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()

def request_json(
    url: str,
    api_key: str,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
    timeout: float = 8.0,
) -> tuple[int, Any]:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Accept", "application/json")
    request.add_header("Authorization", f"Bearer {api_key}")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(4 * 1024 * 1024)
            return int(response.status), json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as error:
        raw = error.read(1024 * 1024)
        try:
            body: Any = json.loads(raw.decode("utf-8"))
        except Exception:
            body = raw.decode("utf-8", errors="replace")
        return int(error.code), body

def normalize_base_url(raw: str) -> str:
    value = raw.rstrip("/")
    if not value.endswith("/v1"):
        value += "/v1"
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme != "http" or parsed.hostname not in LOOPBACK_HOSTS:
        raise ValueError("the remediation provider must be an HTTP loopback endpoint")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("provider URL must not contain credentials, query, or fragment")
    return value

def physical_memory_bytes() -> int | None:
    try:
        result = subprocess.run(
            ["sysctl", "-n", "hw.memsize"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=3,
            check=False,
        )
        if result.returncode == 0:
            return int(result.stdout.strip())
    except Exception:
        pass
    try:
        return int(os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE"))
    except Exception:
        return None

def budget_profile(memory_bytes: int | None) -> dict[str, int]:
    gib = None if memory_bytes is None else memory_bytes / (1024 ** 3)
    if gib is None or gib < 24:
        defaults = (16384, 4096, 14, 12)
    elif gib < 32:
        defaults = (32768, 6144, 18, 15)
    elif gib < 64:
        defaults = (65536, 8192, 24, 18)
    else:
        defaults = (98304, 12288, 32, 22)
    context = int(os.getenv("QWEN_CONTEXT_WINDOW", defaults[0]))
    output = int(os.getenv("QWEN_MAX_OUTPUT_TOKENS", defaults[1]))
    tools = int(os.getenv("QWEN_MAX_TOOL_CALLS", defaults[2]))
    turns = int(os.getenv("QWEN_MAX_SESSION_TURNS", defaults[3]))
    if not 8192 <= context <= 262144:
        raise ValueError("QWEN_CONTEXT_WINDOW must be between 8192 and 262144")
    if not 1024 <= output <= min(32768, context // 2):
        raise ValueError("QWEN_MAX_OUTPUT_TOKENS is outside the safe range")
    if not 4 <= tools <= 100 or not 4 <= turns <= 60:
        raise ValueError("Qwen tool or turn budget is outside the safe range")
    return {"context": context, "output": output, "tools": tools, "turns": turns}

def flatten_models(document: Any) -> list[dict[str, Any]]:
    values = document.get("data", []) if isinstance(document, dict) else []
    models: list[dict[str, Any]] = []
    for item in values:
        if isinstance(item, str):
            models.append({"id": item})
        elif isinstance(item, dict) and isinstance(item.get("id"), str):
            models.append(item)
    return models

def model_is_target(model: dict[str, Any]) -> tuple[bool, bool, str]:
    text = " ".join(
        str(model.get(key, ""))
        for key in ("id", "name", "owned_by", "quantization", "format", "architecture", "bits")
    )
    compact = text.replace(" ", "")
    base_match = bool(MODEL_RE.search(compact))
    quant_match = bool(QUANT_RE.search(text)) or any(
        str(model.get(key, "")).lower() in {"4", "4bit", "int4", "q4", "awq"}
        for key in ("bits", "quantization", "quantization_bits")
    )
    return base_match, quant_match, text

def deep_merge(existing: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    result = dict(existing)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result

def safety_overlay() -> dict[str, Any]:
    hook = {
        "matcher": "run_shell_command",
        "hooks": [{
            "type": "command",
            "command": 'python3 ".forge-qwen-remediation/scripts/qwen_pretool_guard.py"',
            "name": "forge-do-not-ship-guard",
            "timeout": 10000,
        }],
    }
    return {
        "tools": {"approvalMode": "yolo"},
        "memory": {
            "enableManagedAutoMemory": False,
            "enableManagedAutoDream": False,
            "enableAutoSkill": False,
            "enableTeamMemory": False,
            "enableTeamMemorySync": False,
        },
        "privacy": {"usageStatisticsEnabled": False},
        "review": {"attribution": False},
        "general": {"chatRecording": True, "preventSystemSleep": True},
        "hooks": {"PreToolUse": [hook]},
    }


def merge_safety_settings(
    existing: dict[str, Any],
) -> dict[str, Any]:
    overlay = safety_overlay()
    overlay_without_hooks = {
        key: value for key, value in overlay.items() if key != "hooks"
    }
    merged = deep_merge(existing, overlay_without_hooks)

    existing_hooks = existing.get("hooks", {})
    hooks = dict(existing_hooks) if isinstance(existing_hooks, dict) else {}
    pre_tool = hooks.get("PreToolUse", [])
    retained: list[Any] = []
    if isinstance(pre_tool, list):
        for entry in pre_tool:
            if not isinstance(entry, dict):
                retained.append(entry)
                continue
            nested = entry.get("hooks", [])
            names = {
                hook.get("name")
                for hook in nested
                if isinstance(hook, dict)
            } if isinstance(nested, list) else set()
            if "forge-do-not-ship-guard" not in names:
                retained.append(entry)
    required = safety_overlay()["hooks"]["PreToolUse"][0]
    hooks["PreToolUse"] = [*retained, required]
    merged["hooks"] = hooks
    return merged

def provider_entry(
    base_url: str,
    model_id: str,
    budget: dict[str, int],
    include_optional_reasoning: bool,
) -> dict[str, Any]:
    generation: dict[str, Any] = {
        "timeout": 600000,
        "streamIdleTimeoutMs": 600000,
        "maxRetries": 1,
        "contextWindowSize": budget["context"],
        "samplingParams": {
            "temperature": 1.0,
            "top_p": 0.95,
            "top_k": 20,
            "max_tokens": budget["output"],
            "presence_penalty": 0.0,
        },
    }
    if include_optional_reasoning:
        generation["extra_body"] = {
            "chat_template_kwargs": {
                "enable_thinking": True,
                "preserve_thinking": True,
            },
            "reasoning_effort": "xhigh",
        }
    return {
        "id": model_id,
        "name": "Qwen3.8 27B 4-bit local",
        "envKey": "FORGE_QWEN_LOCAL_API_KEY",
        "baseUrl": base_url,
        "generationConfig": generation,
    }

def provider_probe(
    base_url: str,
    api_key: str,
    model_id: str,
    include_optional: bool,
) -> tuple[bool, int | None, Any]:
    body: dict[str, Any] = {
        "model": model_id,
        "messages": [{"role": "user", "content": "Reply with OK."}],
        "temperature": 0,
        "max_tokens": 8,
        "stream": False,
    }
    if include_optional:
        body.update({
            "chat_template_kwargs": {
                "enable_thinking": True,
                "preserve_thinking": True,
            },
            "reasoning_effort": "xhigh",
        })
    try:
        status, value = request_json(
            base_url + "/chat/completions",
            api_key,
            method="POST",
            payload=body,
            timeout=90,
        )
        return 200 <= status < 300, status, value
    except Exception as error:
        return False, None, str(error)

def backup(path: Path) -> str | None:
    if not path.exists():
        return None
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    destination = path.with_name(path.name + f".backup-{stamp}")
    shutil.copy2(path, destination)
    return str(destination)

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--base-url")
    parser.add_argument("--model-id")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--no-provider-probe", action="store_true")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    qwen_dir = repo / ".qwen"
    qwen_dir.mkdir(parents=True, exist_ok=True)
    state_dir = repo / ".forge-qwen-state"
    state_dir.mkdir(parents=True, exist_ok=True)
    settings_path = qwen_dir / "settings.json"
    api_key = os.getenv("FORGE_QWEN_LOCAL_API_KEY", "local-only")

    report: dict[str, Any] = {
        "schema_version": 1,
        "captured_at": utc_now(),
        "configured": False,
        "model_match": False,
        "quantization_verified": False,
        "candidate_endpoints": [],
        "downgrades": [],
    }

    endpoints: list[str] = []
    for raw in (args.base_url, os.getenv("QWEN_OPENAI_BASE_URL"), *DEFAULT_ENDPOINTS):
        if not raw:
            continue
        try:
            normalized = normalize_base_url(raw)
        except ValueError as error:
            if args.strict and raw in {args.base_url, os.getenv("QWEN_OPENAI_BASE_URL")}:
                raise SystemExit(str(error))
            continue
        if normalized not in endpoints:
            endpoints.append(normalized)

    selected_url: str | None = None
    models: list[dict[str, Any]] = []
    for endpoint in endpoints:
        attempt: dict[str, Any] = {"base_url": endpoint, "available": False}
        try:
            status, document = request_json(endpoint + "/models", api_key, timeout=5)
            attempt["http_status"] = status
            if 200 <= status < 300:
                models = flatten_models(document)
                attempt["available"] = True
                attempt["models"] = [model["id"] for model in models]
                selected_url = endpoint
                report["candidate_endpoints"].append(attempt)
                break
            attempt["error"] = str(document)[:1000]
        except Exception as error:
            attempt["error"] = str(error)
        report["candidate_endpoints"].append(attempt)

    chosen: dict[str, Any] | None = None
    requested_model = args.model_id or os.getenv("QWEN_MODEL_ID")
    if selected_url:
        if requested_model:
            chosen = next((model for model in models if model.get("id") == requested_model), None)
            if chosen is None:
                report["error"] = f"requested model is not exposed by provider: {requested_model}"
        else:
            candidates = []
            for model in models:
                base_match, quant_match, _ = model_is_target(model)
                if base_match:
                    candidates.append((not quant_match, str(model["id"]), model))
            if candidates:
                candidates.sort(key=lambda item: (item[0], item[1]))
                chosen = candidates[0][2]

    existing: dict[str, Any] = {}
    if settings_path.is_file():
        try:
            existing = json.loads(settings_path.read_text(encoding="utf-8"))
        except Exception as error:
            raise SystemExit(f"invalid existing .qwen/settings.json: {error}")
    merged = merge_safety_settings(existing)
    backup_path = None

    if selected_url and chosen:
        base_match, quant_match, identity_text = model_is_target(chosen)
        accept_unverified = os.getenv("QWEN_ACCEPT_UNVERIFIED_QUANTIZATION") == "1"
        report.update({
            "base_url": selected_url,
            "model_id": chosen["id"],
            "model_match": base_match,
            "quantization_verified": quant_match,
            "quantization_evidence": identity_text,
        })
        budget = budget_profile(physical_memory_bytes())
        include_optional = True
        if (
            not args.no_provider_probe
            and os.getenv("QWEN_SKIP_PROVIDER_COMPLETION_PROBE") != "1"
        ):
            optional_ok, optional_status, optional_detail = provider_probe(
                selected_url, api_key, chosen["id"], True
            )
            report["optional_reasoning_probe"] = {
                "passed": optional_ok,
                "http_status": optional_status,
                "detail": str(optional_detail)[:2000],
            }
            if not optional_ok:
                base_ok, base_status, base_detail = provider_probe(
                    selected_url, api_key, chosen["id"], False
                )
                report["base_completion_probe"] = {
                    "passed": base_ok,
                    "http_status": base_status,
                    "detail": str(base_detail)[:2000],
                }
                if base_ok:
                    include_optional = False
                    report["downgrades"].append(
                        "provider rejected optional thinking/reasoning request fields"
                    )
                elif args.strict:
                    report["error"] = "provider completion probe failed"

        entry = provider_entry(selected_url, chosen["id"], budget, include_optional)
        providers = merged.setdefault("modelProviders", {}).setdefault("openai", [])
        if not isinstance(providers, list):
            providers = []
        providers = [
            value for value in providers
            if not (isinstance(value, dict) and value.get("id") == chosen["id"])
        ]
        providers.insert(0, entry)
        merged["modelProviders"]["openai"] = providers
        security = merged.setdefault("security", {})
        auth = security.setdefault("auth", {})
        auth["selectedType"] = "openai"
        merged["model"] = {
            **merged.get("model", {}),
            "name": chosen["id"],
            "maxSessionTurns": budget["turns"],
            "maxWallTimeSeconds": 2700,
            "maxToolCalls": budget["tools"],
            "sessionTokenLimit": max(
                8192, budget["context"] - budget["output"] - 2048
            ),
        }
        report.update({
            "context_window_size": budget["context"],
            "max_output_tokens": budget["output"],
            "max_tool_calls": budget["tools"],
            "max_session_turns": budget["turns"],
            "optional_reasoning_fields_enabled": include_optional,
            "configured": (
                base_match
                and (quant_match or accept_unverified)
                and not report.get("error")
            ),
        })
        if not quant_match and accept_unverified:
            report["downgrades"].append(
                "4-bit quantization accepted by explicit environment override"
            )
    else:
        report.setdefault(
            "error",
            "no reachable loopback provider exposing Qwen3.8-27B was found",
        )

    if merged != existing:
        backup_path = backup(settings_path)
        temporary = settings_path.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8")
        os.replace(temporary, settings_path)
    report["settings_path"] = str(settings_path)
    report["settings_backup"] = backup_path
    profile_path = state_dir / "qwen-provider.json"
    profile_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))

    if args.strict:
        if not selected_url or not chosen or not report.get("model_match"):
            return 69
        if (
            not report.get("quantization_verified")
            and os.getenv("QWEN_ACCEPT_UNVERIFIED_QUANTIZATION") != "1"
        ):
            print(
                "4-bit quantization was not verified from provider metadata. "
                "Set QWEN_ACCEPT_UNVERIFIED_QUANTIZATION=1 only after verifying "
                "the loaded artifact.",
                file=sys.stderr,
            )
            return 69
        if not report.get("configured"):
            return 69
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
