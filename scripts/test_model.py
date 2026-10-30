#!/usr/bin/env python3
"""Smoke-test one LiteLLM alias through OpenAI-compatible Chat Completions."""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://127.0.0.1:4000/v1").rstrip("/")


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: gw-test-model MODEL_ALIAS [prompt...]", file=sys.stderr)
        return 2
    model = sys.argv[1]
    prompt = " ".join(sys.argv[2:]) or "Reply with exactly: GATEWAY_MODEL_OK"
    key = os.environ.get("LITELLM_MASTER_KEY", "").strip()
    if not key:
        print("ERROR: LITELLM_MASTER_KEY is empty; check gateway/.env.", file=sys.stderr)
        return 2
    payload = json.dumps({
        "model": model,
        "max_tokens": 100,
        "messages": [{"role": "user", "content": prompt}],
    }).encode("utf-8")
    request = urllib.request.Request(
        f"{BASE_URL}/chat/completions",
        data=payload,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            body = json.loads(response.read().decode("utf-8"))
            print(f"HTTP {response.status} | model={body.get('model', model)}")
            choices = body.get("choices", [])
            if choices:
                content = choices[0].get("message", {}).get("content", "")
                if isinstance(content, str):
                    print(content)
                else:
                    print(json.dumps(content, ensure_ascii=False))
            else:
                print(json.dumps(body, indent=2, ensure_ascii=False))
            return 0
    except urllib.error.HTTPError as exc:
        body = exc.read(3000).decode("utf-8", errors="replace")
        print(f"HTTP {exc.code}: {body}", file=sys.stderr)
        return 1
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
