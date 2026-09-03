#!/usr/bin/env python3
from __future__ import annotations
import argparse
import json
from pathlib import Path
from typing import Any

def parse_document(text: str) -> Any:
    text = text.strip()
    try:
        return json.loads(text)
    except Exception:
        pass
    for index, character in enumerate(text):
        if character not in "[{":
            continue
        try:
            return json.loads(text[index:])
        except Exception:
            continue
    raise ValueError("Qwen output did not contain valid JSON")

def maybe_json(value: Any) -> Any:
    if isinstance(value, (dict, list)):
        return value
    if isinstance(value, str):
        stripped = value.strip()
        try:
            return json.loads(stripped)
        except Exception:
            pass
        for index, character in enumerate(stripped):
            if character not in "[{":
                continue
            try:
                return json.loads(stripped[index:])
            except Exception:
                continue
    return None

def normalize(document: Any) -> dict[str, Any]:
    messages = document if isinstance(document, list) else [document]
    session_id = None
    model = None
    result = None
    subtype = None
    is_error = None
    for item in messages:
        if not isinstance(item, dict):
            continue
        session_id = item.get("session_id", session_id)
        model = item.get("model", model)
        if item.get("type") == "assistant" and isinstance(item.get("message"), dict):
            model = item["message"].get("model", model)
        if item.get("type") == "result":
            result = item.get("result")
            subtype = item.get("subtype")
            is_error = item.get("is_error")
    structured = maybe_json(result)
    if structured is None:
        for item in reversed(messages):
            if not isinstance(item, dict):
                continue
            for key in ("structured_output", "output", "content"):
                structured = maybe_json(item.get(key))
                if structured is not None:
                    break
            if structured is not None:
                break
    return {
        "session_id": session_id,
        "model": model,
        "subtype": subtype,
        "is_error": is_error,
        "result": result,
        "structured": structured,
        "message_count": len(messages),
    }

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("--output")
    args = parser.parse_args()
    value = normalize(
        parse_document(
            Path(args.input).read_text(encoding="utf-8", errors="replace")
        )
    )
    text = json.dumps(value, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
    else:
        print(text, end="")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
