#!/usr/bin/env python3
"""Sync LiteLLM's live model aliases into OpenCode V2's catalog provider."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

GATEWAY_DIR = Path(__file__).resolve().parents[1]
BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://127.0.0.1:4000/v1").rstrip("/")
CONFIG_PATH = GATEWAY_DIR / "opencode.json"
COMPAT_PACKAGE = "@opencode-ai/ai/providers/openai-compatible"
FRIENDLY_NAMES = {
    "free-workhorse": "Gemini Flash — Free Default",
    "premium": "Gemini Pro — Premium with Fallbacks",
    "bedrock-sonnet": "Claude Sonnet — Bedrock",
    "bedrock-opus": "Claude Opus — Bedrock",
    "free-openai": "OpenAI GPT-4o mini",
    "free-anthropic": "Claude Haiku",
    "free-kimi": "Moonshot Kimi",
    "free-glm": "GLM Flash — Z.ai",
    "free-openrouter": "Nemotron — OpenRouter Free",
}


def fetch_model_ids() -> list[str]:
    key = os.environ.get("LITELLM_MASTER_KEY", "").strip()
    if not key:
        raise RuntimeError("LITELLM_MASTER_KEY is empty. Load gateway/.env using ai-env.sh first.")
    request = urllib.request.Request(
        f"{BASE_URL}/models",
        headers={"Authorization": f"Bearer {key}", "Accept": "application/json"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read(1500).decode("utf-8", errors="replace")
        raise RuntimeError(f"LiteLLM /v1/models returned HTTP {exc.code}: {body}") from None
    except (urllib.error.URLError, TimeoutError) as exc:
        raise RuntimeError(f"Could not reach LiteLLM at {BASE_URL}: {exc}") from None
    except json.JSONDecodeError:
        raise RuntimeError("LiteLLM /v1/models returned invalid JSON.") from None

    ids: list[str] = []
    for item in payload.get("data", []):
        if isinstance(item, dict):
            model_id = item.get("id")
            if isinstance(model_id, str) and model_id and model_id not in ids:
                ids.append(model_id)
    if not ids:
        raise RuntimeError("LiteLLM returned no model IDs; config was not changed.")
    return ids


def make_model_entry(model_id: str) -> dict:
    # OpenCode v2.0.24/2.0.25 has a reported issue where completely new custom
    # provider IDs are parsed but unavailable at model-resolution time. Overlay
    # the gateway models on the existing `opencode` catalog provider instead.
    # The model-level package overrides the built-in runtime for these entries.
    return {
        "name": FRIENDLY_NAMES.get(model_id, model_id),
        "modelID": model_id,
        "package": COMPAT_PACKAGE,
        "settings": {
            "baseURL": BASE_URL,
            "apiKey": "{env:LITELLM_MASTER_KEY}",
        },
        "capabilities": {"tools": True, "input": ["text"], "output": ["text"]},
    }


def previous_gateway_alias(config: dict) -> str:
    previous_model = config.get("model", "")
    if not isinstance(previous_model, str):
        return ""
    if previous_model.startswith("litellm/"):
        return previous_model.split("/", 1)[1]
    if previous_model.startswith("opencode/gw-"):
        return previous_model.split("/", 1)[1][3:]
    return ""


def update_config(model_ids: list[str]) -> Path | None:
    config: dict = {}
    if CONFIG_PATH.exists():
        try:
            config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"Existing {CONFIG_PATH} is unreadable; left unchanged: {exc}") from None

    config["$schema"] = "https://opencode.ai/config.json"
    config.pop("providers", None)  # old overlay format, ignored by 2.2.x

    provider = config.setdefault("provider", {})
    provider["gateway"] = {
        "npm": "@ai-sdk/openai-compatible",
        "name": "My Gateway (LiteLLM)",
        "options": {"baseURL": BASE_URL, "apiKey": "{env:LITELLM_MASTER_KEY}"},
        "models": {m: {"name": FRIENDLY_NAMES.get(m, m)} for m in model_ids},
    }

    # Only manage the default model if it's unset or already a gateway model.
    # If you picked a non-gateway model (e.g. another provider), leave it alone.
    current = config.get("model", "")
    if not current or (isinstance(current, str) and current.startswith("gateway/")):
        old_alias = current.split("/", 1)[1] if current.startswith("gateway/") else ""
        default_id = old_alias if old_alias in model_ids else (
            "free-workhorse" if "free-workhorse" in model_ids else model_ids[0])
        config["model"] = f"gateway/{default_id}"

    tmp = CONFIG_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    json.loads(tmp.read_text(encoding="utf-8"))
    tmp.replace(CONFIG_PATH)
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--list", action="store_true", help="list aliases without changing OpenCode config")
    mode.add_argument("--write", action="store_true", help="write/update gateway/opencode.json (default)")
    args = parser.parse_args()
    try:
        model_ids = fetch_model_ids()
        if args.list:
            print("\n".join(model_ids))
            return 0
        backup = update_config(model_ids)
        print(f"Updated: {CONFIG_PATH}")
        if backup:
            print(f"Backup:  {backup}")
        print(f"Registered {len(model_ids)} aliases under provider 'gateway':")
        for model_id in model_ids:
            print(f"  gateway/{model_id}")
        default_model = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))["model"]
        print(f"Default: {default_model}")
        return 0
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
