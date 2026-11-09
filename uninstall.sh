#!/usr/bin/env bash
# ===========================================================================
# uninstall.sh — Remove the LiteLLM gateway macOS service
#
# Stops the LaunchAgent and removes the plist. Optionally cleans up
# the virtual environment, .env, and logs.
# ===========================================================================
set -eo pipefail

GATEWAY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
  _G=$'\033[32m' _R=$'\033[31m' _Y=$'\033[33m' _C=$'\033[36m' _B=$'\033[1m' _0=$'\033[0m'
else
  _G='' _R='' _Y='' _C='' _B='' _0=''
fi
info() { printf '  %s✓%s %s\n' "$_G" "$_0" "$1"; }
warn() { printf '  %s!%s %s\n' "$_Y" "$_0" "$1"; }
step() { printf '\n%s%s%s\n' "$_B$_C" "$1" "$_0"; }

printf '\n%s  LiteLLM AI Gateway — Uninstall%s\n' "$_B" "$_0"

# --- Stop and remove the LaunchAgent ----------------------------------------
step "Removing background service"

if [ -f "$GATEWAY_DIR/.launchd-label" ]; then
  LABEL="$(cat "$GATEWAY_DIR/.launchd-label")"
  TARGET="gui/$(id -u)/$LABEL"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

  if launchctl print "$TARGET" >/dev/null 2>&1; then
    launchctl bootout "$TARGET" 2>/dev/null || true
    info "Service stopped"
  else
    info "Service was not running"
  fi

  [ -f "$PLIST" ] && rm "$PLIST" && info "LaunchAgent plist removed"
  rm -f "$GATEWAY_DIR/.launchd-label"
  info "Label file removed"
else
  warn "No .launchd-label found — service may not have been installed via setup.sh"
fi

# --- Optional cleanup -------------------------------------------------------
step "Optional cleanup"

printf '  Remove Python virtual environment (venv/)? [y/N]: '
read -r choice
[[ "$choice" =~ ^[yY] ]] && rm -rf "$GATEWAY_DIR/venv" && info "venv removed"

printf '  Remove .env (contains your API keys)? [y/N]: '
read -r choice
[[ "$choice" =~ ^[yY] ]] && rm -f "$GATEWAY_DIR/.env" && info ".env removed"

printf '  Remove gateway.log? [y/N]: '
read -r choice
[[ "$choice" =~ ^[yY] ]] && rm -f "$GATEWAY_DIR/gateway.log" && info "Log removed"

# --- Done -------------------------------------------------------------------
step "Uninstall complete"
printf '  Repository files remain. Delete the directory to fully remove:\n'
printf '    rm -rf %s\n\n' "$GATEWAY_DIR"
