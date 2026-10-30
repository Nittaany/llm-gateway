#!/usr/bin/env bash
set -u

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

LOCAL_LABEL_FILE="$PROJECT_DIR/.launchd-label"

if [ ! -f "$LOCAL_LABEL_FILE" ]; then
  echo "ERROR: Local LaunchAgent label file not found: $LOCAL_LABEL_FILE" >&2
  exit 1
fi

IFS= read -r LABEL < "$LOCAL_LABEL_FILE"

if [ -z "$LABEL" ] || [[ "$LABEL" == *[!A-Za-z0-9.-]* ]]; then
  echo "ERROR: Invalid LaunchAgent label in $LOCAL_LABEL_FILE" >&2
  exit 1
fi
DOMAIN="gui/$(id -u)"
TARGET="$DOMAIN/$LABEL"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HEALTH_URL="http://127.0.0.1:4000/health/liveliness"

cd "$PROJECT_DIR" || exit 1

health_code() {
  curl -sS -o /dev/null -w '%{http_code}' \
    --max-time 2 "$HEALTH_URL" 2>/dev/null || true
}

job_pid() {
  launchctl print "$TARGET" 2>/dev/null |
    awk '$1 == "pid" && $2 == "=" { print $3; exit }'
}

listener_pid() {
  lsof -tiTCP:4000 -sTCP:LISTEN 2>/dev/null | head -n 1
}

if [ ! -f "$PLIST" ]; then
  echo "ERROR: LaunchAgent plist not found: $PLIST" >&2
  exit 1
fi

if ! plutil -lint "$PLIST" >/dev/null; then
  echo "ERROR: LaunchAgent plist is invalid." >&2
  exit 1
fi

if launchctl print "$TARGET" >/dev/null 2>&1; then
  JOB_PID="$(job_pid)"
  LISTENER_PID="$(listener_pid)"
  HTTP_CODE="$(health_code)"

  if [ -n "$LISTENER_PID" ] &&
     [ -n "$JOB_PID" ] &&
     [ "$LISTENER_PID" != "$JOB_PID" ]; then
    echo "ERROR: Port 4000 belongs to PID $LISTENER_PID,"
    echo "but launchd reports PID $JOB_PID."
    echo "Refusing to kill or replace an unmanaged process."
    exit 1
  fi

  if [ "$HTTP_CODE" = "200" ] &&
     [ -n "$JOB_PID" ] &&
     [ "$LISTENER_PID" = "$JOB_PID" ]; then
    echo "OK: launchd-managed gateway is already healthy (PID $JOB_PID)."
    exit 0
  fi

  if [ -n "$LISTENER_PID" ] && [ -z "$JOB_PID" ]; then
    echo "ERROR: Port 4000 is occupied, but launchd has no process PID."
    echo "Inspect the service before restarting it."
    exit 1
  fi

  echo "Gateway is unhealthy; asking launchd to restart it..."
  launchctl kickstart -k "$TARGET" || {
    echo "ERROR: launchd could not restart the service." >&2
    exit 1
  }
else
  LISTENER_PID="$(listener_pid)"

  if [ -n "$LISTENER_PID" ]; then
    echo "ERROR: Port 4000 is occupied by PID $LISTENER_PID,"
    echo "but the LaunchAgent is not registered."
    echo "Stop that manually started gateway safely, then rerun this script."
    exit 1
  fi

  echo "Registering the LaunchAgent..."
  launchctl bootstrap "$DOMAIN" "$PLIST" || {
    echo "ERROR: Could not register the LaunchAgent." >&2
    exit 1
  }
fi

echo "Waiting for launchd-managed gateway health..."

for i in $(seq 1 60); do
  JOB_PID="$(job_pid)"
  LISTENER_PID="$(listener_pid)"
  HTTP_CODE="$(health_code)"

  if [ "$HTTP_CODE" = "200" ] &&
     [ -n "$JOB_PID" ] &&
     [ "$LISTENER_PID" = "$JOB_PID" ]; then
    echo "PASS: Gateway is healthy under launchd."
    echo "PID: $JOB_PID"
    exit 0
  fi

  sleep 1
done

echo "ERROR: Gateway did not become healthy within 60 seconds."
launchctl print "$TARGET" 2>&1 | grep -E \
  'state =|runs =|pid =|last exit code' || true
echo
tail -n 40 "$PROJECT_DIR/gateway.log"
exit 1
