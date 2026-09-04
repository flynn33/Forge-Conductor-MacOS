#!/bin/bash
set -euo pipefail
if command -v qwen >/dev/null 2>&1; then
  qwen --version || true
  exit 0
fi
if [[ "${QWEN_AUTO_INSTALL:-0}" != "1" ]]; then
  echo "Qwen Code CLI is not installed. Set QWEN_AUTO_INSTALL=1 to permit installation." >&2
  exit 69
fi
if command -v brew >/dev/null 2>&1; then
  brew install qwen-code
elif command -v npm >/dev/null 2>&1; then
  major="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || true)"
  if [[ -z "$major" || "$major" -lt 22 ]]; then
    echo "Qwen Code requires Node.js 22 or newer." >&2
    exit 69
  fi
  npm install -g @qwen-code/qwen-code@latest
else
  echo "Neither Homebrew nor npm is available." >&2
  exit 69
fi
command -v qwen >/dev/null 2>&1 || {
  echo "Qwen Code installation did not expose qwen on PATH" >&2
  exit 69
}
qwen --version
