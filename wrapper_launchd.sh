#!/bin/bash
# ============================================================
# wrapper_launchd.sh — what macOS launchd actually runs.
# Jobs launchd can't do itself:
#   1. Load keys from .env — SAFELY (tolerates spaces around '=',
#      which naive `source` chokes on; bitten us twice: 2026-10-08 & 10)
#   2. Never crash-loop: if a healthy gateway already owns port
#      4000, WAIT politely instead of fighting it.
# ============================================================
cd "$(dirname "$0")" || exit 1

load_env() {
  while IFS= read -r line; do
    case "$line" in
      \#*|"") continue ;;                              # skip comments and blanks
      [A-Z_]*=*)
        key="${line%%=*}"
        value="${line#*=}"
        # Trim whitespace but preserve actual content values
        value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')
        export "$key=$value"
        ;;
    esac
  done < .env
}

# Wait while any healthy gateway serves port 4000 (e.g. an active dev terminal session)
while [ "$(curl -s -o /dev/null --max-time 2 -w '%{http_code}' http://127.0.0.1:4000/health/liveliness 2>/dev/null)" = "200" ]; do
  sleep 5
done

load_env

# Explicitly ensure your regional variables are ready for Bedrock
export AWS_REGION="ap-southeast-2"

echo "🚀 launchd background agent starting LiteLLM..."
exec ./venv/bin/litellm --config config.yaml --host 127.0.0.1 --port 4000
