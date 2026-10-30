# 04 — Recipes (operational runbook)

> Copy-paste procedures for routine use. Commands assume the project lives at `~/dev/ai-ops` on macOS. Read the notes before running service-control or provider-configuration commands.

## Recipe 1 — Start a normal work session

The gateway is managed by a user LaunchAgent. After logging into macOS, open a project as usual and check the local health endpoint when needed:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:4000/health/liveliness
```

`200` means the health endpoint responded. It does not prove that every provider alias or tool call works.

## Recipe 2 — Inspect or control the gateway service

Find the installed LaunchAgent plist in `~/Library/LaunchAgents/`. The plist is machine-local and is not currently supplied as a portable template in this repository. Read its `Label` value, then use that label below:

```bash
PLIST="$HOME/Library/LaunchAgents/<your-gateway-launchagent>.plist"
LABEL=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST")

launchctl print "gui/$(id -u)/$LABEL"
launchctl kickstart -k "gui/$(id -u)/$LABEL"   # restart the managed job
```

Replace the plist placeholder with the actual filename before running the commands. `bootout` unregisters the service and is not part of routine daily use.

The project controller is:

```bash
"$HOME/dev/ai-ops/gateway/start_gateway.sh"
```

It checks the launchd-managed state and is designed to avoid killing an unknown process that owns port `4000`.

To inspect the runtime log:

```bash
tail -f "$HOME/dev/ai-ops/gateway/gateway.log"
```

Review and redact logs before sharing them; application logs can contain request metadata, local paths, or error details.

## Recipe 3 — Diagnose whether the gateway is responding

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:4000/health/liveliness
lsof -nP -iTCP:4000 -sTCP:LISTEN
```

- HTTP 200 confirms the health endpoint responds.
- `lsof` identifies the process listening on port `4000`.
- A healthy endpoint does not guarantee that a particular upstream provider key, quota, or model is working. Test the target alias separately.

## Recipe 4 — List and test model aliases

List the aliases exposed by LiteLLM:

```bash
GW="$HOME/dev/ai-ops/gateway"
"$GW/bin/gw-models"
```

Test one alias through the gateway:

```bash
"$GW/bin/gw-test-model" free-workhorse "Reply with exactly: GATEWAY_TEST_OK"
```

Use the actual alias you want to test. A successful test confirms a response for that alias at that time; it does not test tool calling or guarantee future quota.

## Recipe 5 — Add or change a provider route

1. Add the provider credential to `gateway/.env` using the variable name expected by the route. Do not paste the secret into a shell command, source file, or chat transcript.
2. Add or edit the model entry in `gateway/config.yaml`. Set a unique `model_name`, the provider/model identifier, and the corresponding `os.environ/VARIABLE_NAME` reference.
3. Validate the YAML/configuration before restarting the service.
4. Restart the managed LaunchAgent using Recipe 2.
5. Test the new alias with Recipe 4.
6. Record the provider, model identifier, observed result, and any quota limitation in `01-decision-log.md`. Do not record the credential value.

Do not assume that a provider's free tier, model identifier, or tool-call support is permanent. Check current provider terms and test the configured route.

## Recipe 6 — Use OpenCode with the gateway

Use the project launcher rather than calling a raw OpenCode process when you want the shared gateway configuration and environment:

```bash
GW="$HOME/dev/ai-ops/gateway"

"$GW/bin/gw-opencode" models
"$GW/bin/gw-opencode" run \
  --model opencode/gw-free-workhorse \
  "Reply with exactly: OPENCODE_GATEWAY_OK"
```

To open the interactive TUI, run:

```bash
"$HOME/dev/ai-ops/gateway/bin/gw-opencode"
```

Inside the TUI, use `/models` to select a generated gateway model. The `opencode/gw-*` names are OpenCode-side entries that map to bare LiteLLM aliases.

If OpenCode reports `No api key passed in` after an environment/key change, load the gateway environment and restart OpenCode's own service through the documented launcher workflow:

```bash
GW="$HOME/dev/ai-ops/gateway"
source "$GW/ai-env.sh" >/dev/null
unset GATEWAY_API_KEY
"$GW/bin/gw-opencode" service status
"$GW/bin/gw-opencode" service restart
```

The known successful text smoke test returned `OPENCODE_GATEWAY_OK`. Tool calling still needs a separate test.

## Recipe 7 — Refresh OpenCode's generated model catalogue

```bash
"$HOME/dev/ai-ops/gateway/bin/gw-sync-opencode-models"
```

The helper reads the live LiteLLM `/v1/models` catalogue and updates generated `opencode/gw-*` entries in `gateway/opencode.json`. Review the resulting diff before committing it.

## Recipe 8 — Use the graphical coding harness

Configure the graphical client to use:

- **Base URL:** `http://127.0.0.1:4000` with the Anthropic-compatible Messages API mode for the tested setup.
- **Client API key:** the value of `LITELLM_MASTER_KEY` from the local gateway environment.
- **Model:** a bare LiteLLM alias, for example `bedrock-sonnet`.

Do not put upstream Bedrock, Anthropic, Gemini, or other provider credentials in the client. Those remain in `gateway/.env`. The recorded Sonnet connection was reported working by the user; keep the setup under test after client or provider upgrades.

## Recipe 9 — Use the wiretap for client diagnostics

The wiretap is a temporary diagnostic proxy, not a normal part of the request path.

1. Start it in a terminal:

   ```bash
   python3 "$HOME/dev/ai-ops/gateway/wiretap.py"
   ```

2. Temporarily point the client to `http://127.0.0.1:4001` instead of port `4000`.
3. Trigger one request and inspect `/tmp/roo_wiretap.log`.
4. Restore the client's Base URL to port `4000` and stop the proxy with Ctrl+C.

The current wiretap logs selected request metadata and timing/byte counts. It excludes authorization headers and does not log prompt or response text. Do not change it to record secrets or message bodies just to make a trace more detailed.

## Recipe 10 — Handle a port conflict safely

First identify the listener:

```bash
lsof -nP -iTCP:4000 -sTCP:LISTEN
```

Do **not** automatically run `kill`, `kill -9`, or `pkill -f litellm` against an unidentified process. Confirm whether the PID belongs to the LaunchAgent before taking action. Then use the launchd-aware controller or inspect the LaunchAgent state using Recipe 2. The controller is designed to refuse an unknown/unmanaged listener rather than terminate it.

## Recipe 11 — Upgrade LiteLLM carefully

Upgrade the package in the gateway virtual environment, then restart the managed service and verify health:

```bash
GW="$HOME/dev/ai-ops/gateway"
"$GW/venv/bin/pip" install --upgrade 'litellm[proxy]'
```

Use Recipe 2 to restart the LaunchAgent, then run the health check from Recipe 1 and test at least one required alias with Recipe 4. Review LiteLLM release notes and dependency/database migration requirements before upgrading a production-like setup.

## Recipe 12 — Check spend history (feature verification pending)

The project has PostgreSQL/database settings for LiteLLM, but end-to-end verification that request history appears in the UI is still pending. Do not use the dashboard as a source of financial records until this is tested against the current installation.

When validating it, make a harmless test request, inspect the relevant LiteLLM UI/history view, and confirm that the model, timestamp, token counts, and cost appear as expected. Never include the gateway master key in screenshots or logs.
