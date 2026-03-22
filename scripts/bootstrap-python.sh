#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="$ROOT_DIR/.venv"
REQUIREMENTS_FILE="$ROOT_DIR/scripts/requirements.txt"
STAMP_FILE="$VENV_DIR/.requirements-sha256"
HF_CACHE_DIR="$ROOT_DIR/codex-memory/.hf-cache"

mkdir -p "$ROOT_DIR/codex-logs"
mkdir -p "$HF_CACHE_DIR"
[ -f "$ROOT_DIR/codex-logs/system.log" ] || : >"$ROOT_DIR/codex-logs/system.log"

requirements_hash="$(shasum -a 256 "$REQUIREMENTS_FILE" | awk '{ print $1 }')"

if [ ! -x "$VENV_DIR/bin/python" ]; then
  python3 -m venv "$VENV_DIR"
fi

if [ ! -f "$STAMP_FILE" ] || [ "$(cat "$STAMP_FILE")" != "$requirements_hash" ]; then
  "$VENV_DIR/bin/python" -m pip install --upgrade pip >/dev/null
  HF_HOME="$HF_CACHE_DIR" SENTENCE_TRANSFORMERS_HOME="$HF_CACHE_DIR" \
  "$VENV_DIR/bin/python" -m pip install -r "$REQUIREMENTS_FILE"
  printf '%s\n' "$requirements_hash" >"$STAMP_FILE"
fi
