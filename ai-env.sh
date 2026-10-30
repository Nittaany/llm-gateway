#!/usr/bin/env bash
# Shared .env loader + status report. Can be sourced from Bash or Zsh.
# Usage: source ~/dev/ai-ops/gateway/ai-env.sh

# Resolve this file's path whether it is sourced from Bash or Zsh.
if [ -n "${ZSH_VERSION:-}" ]; then
  _ai_env_source="${(%):-%N}"
elif [ -n "${BASH_VERSION:-}" ]; then
  _ai_env_source="${BASH_SOURCE[0]}"
else
  _ai_env_source="$0"
fi
_ai_ops_dir="$(cd -- "$(dirname -- "$_ai_env_source")" 2>/dev/null && pwd -P)" || {
  printf '\033[31m[ERROR]\033[0m Could not resolve ai-env.sh directory.\n' >&2
  return 1 2>/dev/null || exit 1
}
_ai_env_file="$_ai_ops_dir/.env"

# Use terminal colors only when output is interactive.
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
  _AI_GREEN=$'\033[32m'
  _AI_RED=$'\033[31m'
  _AI_YELLOW=$'\033[33m'
  _AI_CYAN=$'\033[36m'
  _AI_RESET=$'\033[0m'
else
  _AI_GREEN=''; _AI_RED=''; _AI_YELLOW=''; _AI_CYAN=''; _AI_RESET=''
fi

if [ ! -f "$_ai_env_file" ]; then
  printf '%s[ERROR]%s .env not found at: %s\n' "$_AI_RED" "$_AI_RESET" "$_ai_env_file" >&2
  unset _ai_env_source _ai_ops_dir _ai_env_file _AI_GREEN _AI_RED _AI_YELLOW _AI_CYAN _AI_RESET
  return 1 2>/dev/null || exit 1
fi

# Parse KEY=value without evaluating shell code. Trims whitespace around keys
# and value edges, supports spaces around '=', and removes matching outer quotes.
# Values are exported literally; '$', backticks, '&', and other characters aren't executed.
_ai_env_keys=()
_ai_line_no=0
while IFS= read -r _ai_line || [ -n "$_ai_line" ]; do
  _ai_line_no=$((_ai_line_no + 1))
  _ai_line="${_ai_line%$'\r'}"
  _ai_line="$(printf '%s' "$_ai_line" | sed -e 's/^[[:space:]]*//')"
  [ -z "$_ai_line" ] && continue
  case "$_ai_line" in \#*) continue ;; esac
  case "$_ai_line" in *=*) ;; *) continue ;; esac

  _ai_key="${_ai_line%%=*}"
  _ai_value="${_ai_line#*=}"
  _ai_key="$(printf '%s' "$_ai_key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  _ai_value="$(printf '%s' "$_ai_value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  if ! [[ "$_ai_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    printf '%s[WARN]%s Skipping malformed .env assignment (line %s).\n' "$_AI_YELLOW" "$_AI_RESET" "$_ai_line_no" >&2
    continue
  fi

  case "$_ai_value" in
    \"*\") _ai_value="${_ai_value#\"}"; _ai_value="${_ai_value%\"}" ;;
    \'*\') _ai_value="${_ai_value#\'}"; _ai_value="${_ai_value%\'}" ;;
  esac
  export "$_ai_key=$_ai_value"

  _ai_seen=false
  for _ai_existing in "${_ai_env_keys[@]}"; do
    if [ "$_ai_existing" = "$_ai_key" ]; then _ai_seen=true; break; fi
  done
  if [ "$_ai_seen" = false ]; then _ai_env_keys+=("$_ai_key"); fi
done < "$_ai_env_file"

# Region used by this gateway; do not require AWS CLI/long-term IAM credentials
# when the Bedrock bearer API key is the selected auth method.
_ai_region_was_defaulted=false
if [ -z "${AWS_REGION:-}" ]; then
  if [ -n "${AWS_DEFAULT_REGION:-}" ]; then
    export AWS_REGION="$AWS_DEFAULT_REGION"
  else
    export AWS_REGION="ap-southeast-2"
    _ai_region_was_defaulted=true
  fi
fi

# Always inspect every key referenced by config.yaml, plus every assignment in .env.
_ai_expected_keys=(
  LITELLM_MASTER_KEY DATABASE_URL GEMINI_API_KEY AWS_BEARER_TOKEN_BEDROCK
  OPENAI_API_KEY ANTHROPIC_API_KEY MOONSHOT_API_KEY ZAI_API_KEY
  OPENROUTER_API_KEY AWS_REGION
)
for _ai_key in "${_ai_expected_keys[@]}"; do
  _ai_seen=false
  for _ai_existing in "${_ai_env_keys[@]}"; do
    if [ "$_ai_existing" = "$_ai_key" ]; then _ai_seen=true; break; fi
  done
  if [ "$_ai_seen" = false ]; then _ai_env_keys+=("$_ai_key"); fi
done

printf '\n%sGateway environment check%s\n' "$_AI_CYAN" "$_AI_RESET"
printf 'Loaded from: %s\n' "$_ai_env_file"
_ai_loaded_count=0
_ai_missing_count=0
for _ai_check_key in "${_ai_env_keys[@]}"; do
  if [ -n "$(printenv "$_ai_check_key" 2>/dev/null)" ]; then
    printf '  %s[OK]%s      %s\n' "$_AI_GREEN" "$_AI_RESET" "$_ai_check_key"
    _ai_loaded_count=$((_ai_loaded_count + 1))
  else
    printf '  %s[MISSING]%s %s\n' "$_AI_RED" "$_AI_RESET" "$_ai_check_key"
    _ai_missing_count=$((_ai_missing_count + 1))
  fi
done

if [ "$_ai_region_was_defaulted" = true ]; then
  printf '  %s[INFO]%s AWS_REGION defaulted to ap-southeast-2\n' "$_AI_YELLOW" "$_AI_RESET"
fi
printf '\nLoaded/non-empty: %s | Missing/empty: %s\n' "$_ai_loaded_count" "$_ai_missing_count"
printf 'Missing optional provider keys disable only their associated models; core startup checks run in start_gateway.sh.\n\n'

unset _ai_env_source _ai_ops_dir _ai_env_file _ai_line _ai_key _ai_value _ai_existing _ai_seen _ai_check_key _ai_loaded_count _ai_missing_count _ai_region_was_defaulted _ai_line_no _ai_env_keys _ai_expected_keys
unset _AI_GREEN _AI_RED _AI_YELLOW _AI_CYAN _AI_RESET
