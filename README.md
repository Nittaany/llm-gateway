# AI Ops Gateway — a Beginner-to-Working-System Walkthrough

> **Purpose:** run one locally managed LiteLLM gateway and let multiple coding harnesses select from a shared catalogue of AI models, while keeping upstream credentials in one private `.env` file.
>
> **Current platform:** macOS, with `launchd` managing the gateway.
>
> **Current project path:** `~/dev/ai-ops/gateway`
>
> **Status snapshot:** 30 October 2026. This guide records the setup that was actually exercised during the build session, then distinguishes verified behavior from items that still need testing.

This document is written as a walkthrough, not merely as a handoff. Start at the top if you have never used a model gateway before. If you already have the system running, jump to [daily use](#7-daily-use-no-manual-gateway-startup-needed) or [adding and removing models](#12-add-or-remove-a-model).

## Contents

- [1. What we are building](#1-what-we-are-building)
- [2. Learn the pieces first](#2-learn-the-pieces-first)
- [3. Architecture and request flow](#3-architecture-and-request-flow)
- [4. Current model catalogue](#4-current-model-catalogue)
- [5. Repository layout](#5-repository-layout)
- [6. What must exist before the gateway can run](#6-what-must-exist-before-the-gateway-can-run)
- [7. Daily use: no manual gateway startup needed](#7-daily-use-no-manual-gateway-startup-needed)
- [8. Health, status, logs, and restart commands](#8-health-status-logs-and-restart-commands)
- [9. How OpenCode is connected](#9-how-opencode-is-connected)
- [10. How a graphical/IDE harness is connected](#10-how-a-graphicalide-harness-is-connected)
- [11. Test a model before trusting it](#11-test-a-model-before-trusting-it)
- [12. Add or remove a model](#12-add-or-remove-a-model)
- [13. Understand the model names](#13-understand-the-model-names)
- [14. Environment variables and secrets](#14-environment-variables-and-secrets)
- [15. Recovery and troubleshooting](#15-recovery-and-troubleshooting)
- [16. Current verification status](#16-current-verification-status)
- [17. Preparing the project for GitHub](#17-preparing-the-project-for-github)
- [18. Further reading and engineering history](#18-further-reading-and-engineering-history)

---

## 1. What we are building

The project is a small, owner-controlled AI development environment. Rather than putting a different API key and provider URL into every coding application, the applications send requests to **one local gateway**. The gateway selects the upstream model and uses the appropriate provider credential.

Historically, the project began with a VS Code extension workflow as well as a CLI harness. The previous README records a send-pipeline hang in an earlier Roo Code setup; another extension in the same family worked against the same gateway, and `wiretap.py` was retained as a debugging proxy to observe HTTP traffic. That was an earlier client-side investigation, not a component required for normal operation today.

The intended benefits are:

- **One credential boundary:** upstream provider keys stay in `gateway/.env`; coding clients use the gateway's `LITELLM_MASTER_KEY`.
- **One model catalogue:** aliases are defined in `config.yaml` and exposed by LiteLLM.
- **Multiple harnesses:** OpenCode and a graphical/IDE harness can use the same backend while keeping their own interface, workspaces, and permissions.
- **Central routing:** retry, fallback, and cache rules live in the gateway configuration instead of being duplicated in each client.
- **Background operation:** macOS `launchd` starts and supervises the gateway.
- **Portable project knowledge:** `gateway/docs/` records architecture, decisions, glossary, recipes, and the build history.

### What this is not

- It is **not** a cloud-hosted/public gateway. LiteLLM currently binds to `127.0.0.1:4000`, which is the loopback interface on this Mac. Clients on other devices cannot reach it just because it is running.
- It is **not** a guarantee that every configured upstream model is free or callable at all times. Provider quotas, billing, model availability, and tool-call support vary.
- It is **not** a general-purpose autonomous coding policy. The old `agent-lab` contained a deliberately narrow task loop, and was retired after the experiment. Its local recovery archive was later removed during cleanup. Its automatic branch/task/commit behavior was not promoted into every real project.
- It is **not** a substitute for reviewing code changes, running tests, or keeping backups.

## 2. Learn the pieces first

Think of the system as a desk with several interchangeable tools. Each part has one responsibility.

| Piece | Plain-English job | File or location |
|---|---|---|
| Coding harness | The application that asks questions, reads code, and may use tools to edit/run code | OpenCode CLI, plus a graphical/IDE harness |
| LiteLLM | The switchboard between a client and different model APIs | `gateway/venv/bin/litellm` |
| Model alias | A stable nickname for one configured upstream route | `model_name` under `model_list` in `config.yaml` |
| Provider/model ID | The actual upstream model route LiteLLM calls | `litellm_params.model` in `config.yaml` |
| Gateway master key | The shared client credential accepted by LiteLLM | `LITELLM_MASTER_KEY` in the private `.env` |
| Provider API key/token | A secret used by LiteLLM to authenticate to an upstream provider | Values such as `GEMINI_API_KEY` or `AWS_BEARER_TOKEN_BEDROCK` in `.env` |
| Gateway configuration | Maps aliases to upstream models and defines retries/fallbacks/cache behavior | `gateway/config.yaml` |
| Environment loader | Reads `.env` entries safely and reports presence without printing values | `gateway/ai-env.sh` |
| `launchd` LaunchAgent | macOS process supervisor that starts the gateway and relaunches it after exits | `~/Library/LaunchAgents/com.nitant.litellm-gateway.plist` |
| LaunchAgent wrapper | Loads `.env`, sets the Bedrock region, and runs LiteLLM | `gateway/wrapper_launchd.sh` |
| Gateway controller | Checks the service and asks `launchd` to start/restart it when needed | `gateway/start_gateway.sh` |
| OpenCode central config | Makes the live gateway aliases selectable in OpenCode | `gateway/opencode.json` |
| Model sync helper | Queries the live gateway catalogue and refreshes OpenCode's generated model entries | `gateway/scripts/sync_opencode_models.py` |
| Runtime log | Gateway startup/request/error output | `gateway/gateway.log` |
| Engineering log | Human-readable history of decisions, failures, fixes, and tests | `docs/02-build-log.md` |

### The most important separation

**`config.yaml` tells LiteLLM how to reach models. `opencode.json` tells OpenCode how to reach LiteLLM.** They are not interchangeable:

1. `config.yaml` defines upstream routes and gateway behavior.
2. LiteLLM loads this configuration when its process starts.
3. `GET /v1/models` reports the aliases currently exposed by the running gateway.
4. The sync helper reads that endpoint and generates OpenCode model entries.
5. OpenCode sends requests to the local gateway; it does not need every upstream provider key.

If you add an alias to YAML but do not restart LiteLLM, the running gateway may still be using the old configuration. If you remove an alias from YAML, you must also refresh the OpenCode model list to remove its stale client entry.

## 3. Architecture and request flow

```text
                               YOUR MAC
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  OpenCode CLI                      Graphical / IDE harness          │
│  gw-opencode launcher               custom provider settings         │
│         │                                    │                      │
│         └───────────────┬────────────────────┘                      │
│                         │                                           │
│             HTTP to 127.0.0.1:4000                                   │
│             one client key: LITELLM_MASTER_KEY                       │
│                         │                                           │
│                         ▼                                           │
│              ┌────────────────────────┐                             │
│              │ LiteLLM proxy/gateway  │                             │
│              │ config.yaml            │                             │
│              │ retries/fallback/cache │                             │
│              └────────────┬───────────┘                             │
│                           │                                         │
│                   credentials from .env                             │
│                           │                                         │
└───────────────────────────┼─────────────────────────────────────────┘
                            │ outbound HTTPS
         ┌──────────────────┼───────────────────┐
         ▼                  ▼                   ▼
      Gemini             Bedrock            Other providers
                                    (OpenAI, Anthropic, Kimi,
                                     Z.ai, OpenRouter, etc.)
```

A normal model request follows this path:

1. The harness selects a model alias, for example `bedrock-sonnet`.
2. The harness sends its request to `http://127.0.0.1:4000` (exact path depends on API protocol).
3. LiteLLM checks the client credential `LITELLM_MASTER_KEY`.
4. LiteLLM looks up the alias in `config.yaml`.
5. LiteLLM gets the upstream credential from its environment and calls the provider.
6. LiteLLM sends the provider's response back to the harness.

The client does not normally send the upstream Bedrock/Gemini/etc. key. That is the main security and management advantage of this arrangement.

## 4. Current model catalogue

The following nine aliases were returned by the **running** gateway's authenticated `GET /v1/models` endpoint on 30 October 2026.

| Gateway alias | Configured route | Notes |
|---|---|---|
| `free-workhorse` | `gemini/gemini-flash-latest` | Default fast model; fallback target for `premium` |
| `premium` | `gemini/gemini-3.1-pro-preview` | Intended higher-capability route; configured to fall back to `free-workhorse`, then `free-glm` |
| `bedrock-sonnet` | `bedrock/global.anthropic.claude-sonnet-4-6` | Claude Sonnet through Amazon Bedrock; selected in the graphical/IDE harness and reported working by the user |
| `bedrock-opus` | `bedrock/au.anthropic.claude-opus-4-6-v1` | Claude Opus through Amazon Bedrock; successful direct and LiteLLM tests were observed |
| `free-openai` | `openai/gpt-4o-mini` | The `free-` prefix is an alias label, not a guarantee of free usage or current quota |
| `free-anthropic` | `anthropic/claude-3-5-haiku-latest` | Alias configured; live upstream usability should be tested before relying on it |
| `free-kimi` | `moonshot/moonshot-v1-8k` | Alias configured; check current availability/quota before use |
| `free-glm` | `zai/glm-4.7-flash` | Z.ai route; one planned alternative/fallback |
| `free-openrouter` | `openrouter/nvidia/nemotron-3-ultra-550b-a55b:free` | OpenRouter free-route alias; provider limits may apply |

**Important:** LiteLLM listing an alias means the route is configured and exposed. It does not prove that the upstream credential is valid, has remaining quota, is billable/free, or supports the tool calls a coding harness needs. Test each route.

### Current routing rules

The current `config.yaml` defines:

- `premium` fallback order: `free-workhorse`, then `free-glm`.
- `free-workhorse` fallback: `free-glm`.
- `num_retries: 2` and `retry_after: 5`.
- Local in-memory caching enabled (`cache: true`, local cache).
- `drop_params: true` so unsupported request parameters can be dropped instead of always causing provider errors.
- `general_settings.master_key` sourced from `LITELLM_MASTER_KEY`.
- `general_settings.database_url` sourced from `DATABASE_URL`.

These rules are gateway policy, not features invented by each harness. A fallback can mean the final answer comes from a different model than the one initially selected. When evaluating results or cost, inspect the gateway log and response model field if the distinction matters.

## 5. Repository layout

The live project is organized around `ai-ops/`, with the gateway now acting as the operational center.

```text
ai-ops/
├── gateway/
│   ├── .env                         # private provider keys + gateway key; never publish
│   ├── .gitignore                   # inspect before publishing
│   ├── README.md                    # this walkthrough
│   ├── config.yaml                  # model aliases + routing rules
│   ├── ai-env.sh                    # shared environment loader/status check
│   ├── start_gateway.sh             # launchd-aware health/start/recovery controller
│   ├── wrapper_launchd.sh            # command launched by launchd
│   ├── requirements.txt             # Python dependencies
│   ├── venv/                        # installed environment; normally not versioned
│   ├── gateway.log                  # runtime log; inspect before sharing publicly
│   ├── opencode.json                # generated central OpenCode V2 config
│   ├── wiretap.py                   # legacy request-debugging helper
│   ├── bin/
│   │   ├── gw-opencode              # start OpenCode with gateway env/config
│   │   ├── gw-models                # list current LiteLLM aliases
│   │   ├── gw-sync-opencode-models  # regenerate OpenCode model aliases
│   │   └── gw-test-model            # smoke-test one alias
│   ├── scripts/
│   │   ├── sync_opencode_models.py  # live catalogue → OpenCode config
│   │   └── test_model.py            # Chat Completions smoke test
│   ├── clients/
│   │   └── README.md                # client-specific setup notes
│   └── docs/                       # architecture, decisions, build log, glossary, recipes
```

Two related locations live **outside** this project tree:

- The LaunchAgent plist: `~/Library/LaunchAgents/com.nitant.litellm-gateway.plist`.
- OpenCode's own service/runtime, which may have a process listening on a separate local port such as `127.0.0.1:49374`. That is not the LiteLLM gateway; LiteLLM remains on port `4000`.

The old `agent-lab/` was a toy proof-of-concept with `TASKS.md`, `tasks.py`, tests, an OpenCode config, and `run_harness.sh`. It was archived during migration and later removed from the live project along with its local recovery archive during cleanup. Its history remains in `docs/02-build-log.md`; it is not part of the current runtime.

## 6. What must exist before the gateway can run

This section explains the dependencies rather than pretending that copying the README alone recreates private credentials or the LaunchAgent.

### 6.1 macOS and command-line tools

The observed machine uses macOS, Homebrew Python 3.12, `curl`, `launchctl`, `lsof`, and an installed `opencode` executable. The exact OpenCode version observed during this setup was `2.0.25`.

Check the local versions:

```bash
sw_vers
python3 --version
command -v curl
command -v launchctl
command -v opencode
opencode --version
```

### 6.2 Python virtual environment and LiteLLM

The gateway already has `gateway/venv/` and runs LiteLLM with:

```text
gateway/venv/bin/litellm --config config.yaml --host 127.0.0.1 --port 4000
```

`requirements.txt` records Python dependencies. On a fresh compatible environment, dependency installation would typically be performed in a virtual environment, but this documentation does **not** claim a fresh-machine installation has been tested. Preserve the working `venv` on the current Mac; do not rebuild it merely to use the existing service.

### 6.3 PostgreSQL

Startup logs showed LiteLLM's database URL resolving to PostgreSQL database `litellm` on `localhost:5432`, with no pending migrations at that time. `DATABASE_URL` must point to an available database matching the local environment. Startup also logged `psycopg is not installed; skipping the invalid index check`, a Prisma client warning (`connect(): 'Prisma' object has no attribute '_Prisma__engine'`), and a `trusted_proxy_ranges` warning. The observed process still reached “Application startup complete” and listened on port 4000. These warnings were not repaired in this session; see the build log and do not assume they cannot affect other features.

### 6.4 Private `.env`

`.env` is required. It contains the gateway master key and whichever upstream provider keys are used. Variable names seen in the configuration include:

```dotenv
LITELLM_MASTER_KEY=replace-with-a-private-client-key
DATABASE_URL=postgresql://USER:PASSWORD@localhost:5432/litellm
GEMINI_API_KEY=replace-with-provider-key
AWS_BEARER_TOKEN_BEDROCK=replace-with-bedrock-api-key
OPENAI_API_KEY=replace-if-this-route-is-used
ANTHROPIC_API_KEY=replace-if-this-route-is-used
MOONSHOT_API_KEY=replace-if-this-route-is-used
ZAI_API_KEY=replace-if-this-route-is-used
OPENROUTER_API_KEY=replace-if-this-route-is-used
AWS_REGION=ap-southeast-2
```

These are **placeholders**, not real working values. Use your own authorized provider credentials. Not every key is needed for every model, but the variables referenced by active model entries must be present for those routes to work.

The project has both `ai-env.sh` and the launchd wrapper for environment loading. Use the loader rather than assuming `.env` is a normal shell script; it is parsed as simple `KEY=value` entries. Do not paste actual key values into GitHub, issue reports, or logs.

### 6.5 LaunchAgent setup

The existing plist was found at:

```text
~/Library/LaunchAgents/com.nitant.litellm-gateway.plist
```

Its inspected settings included:

- `Label = com.nitant.litellm-gateway`
- `ProgramArguments = /bin/bash .../gateway/wrapper_launchd.sh`
- `RunAtLoad = true`
- `KeepAlive = true`
- standard output and error both directed to `gateway/gateway.log`

The plist itself is outside the `ai-ops` folder and is not reproduced by `git clone`. A person recreating the project on another Mac must create and validate a user LaunchAgent with paths for that machine. Do not copy a plist containing `/Users/nitant/...` unchanged to another username.

## 7. Daily use: no manual gateway startup needed

The normal daily sequence is:

1. Log into the Mac. The user LaunchAgent is configured to load and keep the gateway running.
2. Open a code project.
3. Run OpenCode through the gateway launcher, or open the graphical/IDE harness using its saved local-gateway provider.
4. Select a model alias and work normally.

### Check the gateway (optional)

```bash
curl -sS -w '\nHTTP %{http_code}\n' \
  http://127.0.0.1:4000/health/liveliness
```

The healthy result observed is:

```text
"I'm alive!"
HTTP 200
```

### Start OpenCode in the current project

From the repository you want OpenCode to work on:

```bash
"$HOME/dev/ai-ops/gateway/bin/gw-opencode"
```

The wrapper deliberately preserves the **current working directory** so OpenCode opens the project you selected, while loading the shared config from `gateway/opencode.json`.

You can also make a headless request:

```bash
"$HOME/dev/ai-ops/gateway/bin/gw-opencode" run \
  --model opencode/gw-free-workhorse \
  "Reply with exactly: OPENCODE_GATEWAY_OK"
```

The exact model reference matters. In the working OpenCode compatibility arrangement, generated model names have the `opencode/gw-` prefix. The underlying LiteLLM alias is still the bare model name, such as `free-workhorse`.

### Do you need `start_gateway.sh` every time?

**No—not for ordinary daily use.** The existing LaunchAgent is the persistent service owner. `KeepAlive` is configured and process-crash recovery was actually tested. `gw-opencode` checks the health endpoint and, if it is unhealthy, asks the gateway controller to recover the service.

Do not use the historical pre-fix instruction “kill whatever owns port 4000.” The current `start_gateway.sh` is a launchd-aware controller: it checks service state, refuses to kill an unrelated listener, keeps a healthy instance, and asks launchd to restart a managed instance if unhealthy. If you edit `config.yaml`, however, an explicit service restart is still needed to load the new file.

A full reboot/login cycle has **not** been tested in this build session. `RunAtLoad` indicates load-time launch, but the final reboot scenario remains on the verification list.

## 8. Health, status, logs, and restart commands

Set some shell variables to make the commands easier to understand:

```bash
GW="$HOME/dev/ai-ops/gateway"
LABEL="com.nitant.litellm-gateway"
TARGET="gui/$(id -u)/$LABEL"
```

### Is the LaunchAgent registered?

```bash
launchctl list | grep -F "$LABEL" || echo "LaunchAgent not listed"
launchctl print "$TARGET"
```

### Which process owns port 4000?

```bash
lsof -nP -iTCP:4000 -sTCP:LISTEN
```

### Read recent logs

```bash
tail -n 80 "$GW/gateway.log"
```

Search for common failures:

```bash
grep -Ei 'ERROR|Exception|Traceback|failed|NoCredentialsError|invalid model' \
  "$GW/gateway.log" | tail -n 60
```

`gateway.log` is the **runtime** log. It may include request errors, prompt-related details depending on logging level, local paths, and stack traces. Inspect and redact it before posting publicly. At the last tree snapshot it was approximately 10.6 MB; a log-rotation policy is not yet documented as implemented. Older log lines also refer to a historical `/Users/nitant/ai-gateway/` path; check timestamp and path before assuming an error belongs to the current `~/dev/ai-ops/gateway` service.

### Restart after editing `config.yaml` or changing `.env`

This deliberately interrupts the current gateway process and in-flight requests. Use it only when a config/environment reload is needed:

```bash
launchctl kickstart -k "gui/$(id -u)/com.nitant.litellm-gateway"

for i in $(seq 1 60); do
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
    http://127.0.0.1:4000/health/liveliness 2>/dev/null || true)"
  if [ "$CODE" = "200" ]; then
    echo "Gateway healthy after restart."
    break
  fi
  sleep 1
done
```

Then verify with `curl` and test the model affected by the change.

### `start_gateway.sh` is a controller, not a foreground server command now

The current script:

- validates the LaunchAgent plist;
- checks if the LaunchAgent is loaded;
- compares the LaunchAgent PID with the process listening on port 4000;
- exits without restarting if the managed gateway is already healthy;
- registers the plist if unloaded and the port is free;
- requests a launchd restart if a managed service is unhealthy;
- refuses to kill an unrelated process on port 4000.

Therefore, running it while the service is healthy prints a message like:

```text
OK: launchd-managed gateway is already healthy (PID 17231).
```

It does not necessarily reload a new `config.yaml` when the health check already passes. Use the explicit `launchctl kickstart -k ...` command above after a config change.

## 9. How OpenCode is connected

### Why there is a central OpenCode config

The live file is:

```text
~/dev/ai-ops/gateway/opencode.json
```

The `gw-opencode` launcher sets the `OPENCODE_CONFIG` environment variable to that file so OpenCode uses a single gateway-owned configuration regardless of which source-code directory is open.

This design avoids copying a provider block into every project. It also avoids inheriting the old toy lab's project-specific settings that allowed all edits and shell commands automatically.

### Why model IDs look different in OpenCode

The gateway exposes aliases like:

```text
free-workhorse
premium
bedrock-sonnet
bedrock-opus
free-glm
```

For the OpenCode V2 version tested (`2.0.25`), a direct custom provider namespace (`litellm/...`) appeared in `opencode models` but failed at execution with errors including `Model unavailable` and `No api key passed in`. The final working sync script uses a compatibility workaround: it overlays gateway routes onto OpenCode's existing catalog provider and exposes them under names such as:

```text
opencode/gw-free-workhorse
opencode/gw-premium
opencode/gw-bedrock-sonnet
opencode/gw-bedrock-opus
opencode/gw-free-glm
```

The model entry's `modelID` tells the OpenAI-compatible runtime which bare LiteLLM alias to send. The `gw-` part is the OpenCode-facing selection name; it is not a new LiteLLM model or provider.

This is a **version-specific compatibility workaround verified on this machine**, not a promise that all future OpenCode releases require it. When upgrading OpenCode, first test the existing configuration before changing it. Review the official [OpenCode V2 provider documentation](https://opencode.ai/v2/docs/providers) for the current schema. The installed sync script used the runtime package spelling that worked in the recorded `2.0.25` session (`@opencode-ai/ai/providers/openai-compatible`). Official V2 examples may use a different package spelling as OpenCode evolves. Preserve the known-working file on this machine; for a fresh/newer OpenCode installation, verify the package name against the docs for that exact version before copying the old workaround.

### Refresh the OpenCode catalogue

```bash
"$HOME/dev/ai-ops/gateway/bin/gw-sync-opencode-models"
```

The script:

1. reads `LITELLM_MASTER_KEY` from the environment (the launcher sources `ai-env.sh` first);
2. queries `GET http://127.0.0.1:4000/v1/models`;
3. reads the alias IDs from the response;
4. backs up the existing `opencode.json`;
5. updates only generated `gw-*` entries in the OpenCode model map while preserving native OpenCode models;
6. writes a validated JSON config.

To list gateway aliases without changing the config:

```bash
"$HOME/dev/ai-ops/gateway/bin/gw-models"
```

A model appearing in `/models` means discovery worked; use a real prompt to verify authentication and upstream availability.

### Authentication workaround that actually succeeded

The final successful sequence in the recorded session was:

```bash
GW="$HOME/dev/ai-ops/gateway"
source "$GW/ai-env.sh" >/dev/null
unset GATEWAY_API_KEY
"$GW/bin/gw-opencode" service status
"$GW/bin/gw-opencode" service restart
"$GW/bin/gw-opencode" run \
  --model opencode/gw-free-workhorse \
  "Reply with exactly: OPENCODE_GATEWAY_OK"
```

OpenCode reported a service endpoint on `127.0.0.1:49374`; the model run returned `OPENCODE_GATEWAY_OK`. The precise underlying reason the earlier service lacked the resolved API key was not conclusively isolated, so the log records this as an empirically successful recovery sequence rather than claiming a fully proven internal root cause.

## 10. How a graphical/IDE harness is connected

The second harness keeps its provider setup in its own app configuration, not in `opencode.json`. It should use the same gateway key, not individual upstream provider keys.

Two API-compatible modes are available through LiteLLM. Use the one that matches the harness's provider type:

### OpenAI-compatible mode

- **Base URL:** `http://127.0.0.1:4000/v1`
- **API key:** the actual value of `LITELLM_MASTER_KEY` from `gateway/.env`
- **Model ID:** a bare alias, such as `free-workhorse`, `bedrock-sonnet`, or `bedrock-opus`
- **Request path:** typically `/v1/chat/completions`

### Anthropic-compatible mode

This was used for the successful Sonnet setup:

- **Base URL:** `http://127.0.0.1:4000`
- **API key:** the actual `LITELLM_MASTER_KEY` value
- **Model ID:** `bedrock-sonnet`
- **Request path:** `/v1/messages`
- **Anthropic version header:** `anthropic-version: 2023-06-01`

The model identifier observed in the harness session included a client-specific provider prefix (`new-provider/bedrock-sonnet`). The model name LiteLLM receives is the bare alias `bedrock-sonnet`.

The exact GUI settings depend on whether the harness calls an OpenAI-compatible or Anthropic-compatible interface. Do not mix the `/v1` URL and request path blindly; match the protocol that the client uses.

### Obtain the gateway key without displaying it

In a Terminal window on the Mac:

```bash
source "$HOME/dev/ai-ops/gateway/ai-env.sh" >/dev/null
printf %s "$LITELLM_MASTER_KEY" | pbcopy
```

This copies the value to the clipboard. Paste it into the harness's API-key field. Do not put the literal string `$LITELLM_MASTER_KEY` into a GUI API-key box; most forms expect the actual secret value.

**Observed status:** the user reported that Sonnet was working in the GUI harness using `bedrock-sonnet`. The request details above describe the configured route; a separate captured raw GUI response was not included in the build record.

## 11. Test a model before trusting it

The fastest useful checks are layered. Start at the bottom and only move up after the previous layer passes.

### Layer A — gateway health

```bash
curl -sS -w '\nHTTP %{http_code}\n' \
  http://127.0.0.1:4000/health/liveliness
```

Expected: HTTP `200`.

### Layer B — model catalogue

```bash
"$HOME/dev/ai-ops/gateway/bin/gw-models"
```

Expected at the last verified snapshot: nine aliases listed in Section 4.

### Layer C — one model through the OpenAI-compatible endpoint

```bash
source "$HOME/dev/ai-ops/gateway/ai-env.sh" >/dev/null
"$HOME/dev/ai-ops/gateway/bin/gw-test-model" free-workhorse
```

The tool tests `/v1/chat/completions` and prints the HTTP status and response content. To test another model, replace `free-workhorse` with a different bare alias. The helper does not prove Anthropic-specific endpoint behavior or coding-agent tool support.

### Layer D — OpenCode request

```bash
"$HOME/dev/ai-ops/gateway/bin/gw-opencode" run \
  --model opencode/gw-free-workhorse \
  "Reply with exactly: OPENCODE_GATEWAY_OK"
```

Expected: `OPENCODE_GATEWAY_OK`. This exact text response succeeded in the recorded session after restarting the OpenCode service.

### Layer E — tool use

A text reply does not prove that tool calling works. When testing tool use, start with a harmless command and explicitly forbid file writes:

```bash
"$HOME/dev/ai-ops/gateway/bin/gw-opencode" run \
  --model opencode/gw-free-workhorse \
  "Use your terminal tool to run printf 'TOOL_CALL_OK\\n'. Do not create, edit, or delete files. Report the exact output."
```

**This tool-use test was recommended but no result was captured in the recorded session. Treat it as not yet verified.** Test tool use separately for each model/provider that you want to use as a coding agent.

## 12. Add or remove a model

The workflow is deliberately centralized. Do not edit each client's API credentials to add a provider.

### Add a model route

1. Confirm you have access to the upstream provider and know its exact API/model identifier.
2. Add the provider credential to the private `gateway/.env` if this key is new.
3. Add a model block under `model_list` in `gateway/config.yaml`. Example shape:

   ```yaml
   - model_name: my-alias
     litellm_params:
       model: provider/actual-model-id
       api_key: os.environ/MY_PROVIDER_API_KEY
   ```

   Replace `provider/actual-model-id` and `MY_PROVIDER_API_KEY` with values from the actual provider/LiteLLM integration. The example is a pattern, not a complete provider-specific recipe; some providers require region, API base, version, or other fields.

4. If adding/removing aliases used by `router_settings.fallbacks`, update those references too.
5. Validate YAML syntax:

   ```bash
   cd "$HOME/dev/ai-ops/gateway"
   ./venv/bin/python3 -c 'import yaml; yaml.safe_load(open("config.yaml")); print("YAML syntax OK")'
   ```

6. Restart the managed gateway so it reads the new YAML/environment:

   ```bash
   launchctl kickstart -k "gui/$(id -u)/com.nitant.litellm-gateway"
   ```

7. Wait for HTTP 200 at `/health/liveliness`.
8. Test the alias directly:

   ```bash
   "$HOME/dev/ai-ops/gateway/bin/gw-test-model" my-alias
   ```

9. Sync OpenCode's model list:

   ```bash
   "$HOME/dev/ai-ops/gateway/bin/gw-sync-opencode-models"
   ```

10. Confirm the alias appears in both `gw-models` and `gw-opencode models`.
11. Configure the same **bare alias** in the GUI/IDE harness if you want it there, then make a real request.

Do not restart the gateway merely to refresh the OpenCode catalogue when the gateway config has not changed; sync is a client-config operation. Conversely, model sync does not reload `config.yaml` into a running LiteLLM process.

### Remove a model route

1. Remove the matching `- model_name: ...` block from `config.yaml`.
2. Remove it from fallback lists, router settings, or other references if present.
3. Remove its provider key from `.env` **only if no other configured route uses it**.
4. Validate YAML, then restart the LaunchAgent to load the removal.
5. Confirm the alias no longer appears in `GET /v1/models` / `gw-models`.
6. Run `gw-sync-opencode-models` to remove stale generated `gw-*` aliases from OpenCode's central config.
7. Remove or disable the alias in the GUI/IDE harness's own model picker if it has a saved copy.

The sync script removes its own stale generated aliases but preserves native OpenCode models. Keep the generated config's backup files until the new model list has been checked.

## 13. Understand the model names

There are three layers of names, and confusing them caused some of the earlier failures.

| Layer | Example | Meaning |
|---|---|---|
| Upstream provider route | `bedrock/au.anthropic.claude-opus-4-6-v1` | Provider-specific model/inference-profile identifier used by LiteLLM |
| LiteLLM alias | `bedrock-opus` | Stable nickname clients send to LiteLLM |
| OpenCode model reference | `opencode/gw-bedrock-opus` | OpenCode-facing model selector name; the generated entry sends the underlying alias `bedrock-opus` |
| GUI harness model ID | `bedrock-opus` (possibly shown with the harness's provider prefix) | The alias to pass in the gateway request, subject to the GUI's own provider naming scheme |

A model name in the catalogue can be selectable while its upstream route still fails. A text-completion test can succeed while a tool call fails. Keep discovery, authentication, upstream request success, and tool compatibility as separate test gates.

## 14. Environment variables and secrets

### Variable roles

- `LITELLM_MASTER_KEY`: client-to-gateway authentication key.
- `GEMINI_API_KEY`: used by the two Gemini routes.
- `AWS_BEARER_TOKEN_BEDROCK`: Bedrock API token used by the two Bedrock routes.
- `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `MOONSHOT_API_KEY`, `ZAI_API_KEY`, `OPENROUTER_API_KEY`: credentials for their configured providers.
- `DATABASE_URL`: connection to the LiteLLM PostgreSQL database.
- `AWS_REGION`: set/defaulted to `ap-southeast-2` for the Bedrock configuration.
- `LITELLM_BASE_URL`: optional override consumed by helper scripts; defaults to `http://127.0.0.1:4000/v1`.

The current `config.yaml` references `AWS_BEARER_TOKEN_BEDROCK`, not `AWS_BEARER_TOKEN`, for its Bedrock model entries. Do not assume an extra environment variable is used just because it exists in `.env`.

### Rules for safe key handling

- Never commit `.env`.
- Never paste a key into this README, `BUILD_LOG.md`, a GitHub issue, or terminal transcript.
- Never publish `gateway.log` without reviewing/redacting it; logs can reveal request context, usernames, paths, and errors.
- Verify ignores before any public push:

  ```bash
  cd "$HOME/dev/ai-ops"
  git check-ignore -v gateway/.env gateway/gateway.log gateway/venv
  git status --short
  ```

  If `.env` is not ignored, fix `.gitignore` before staging anything. If a secret has ever been committed, deleting the file is not enough; rotate the exposed credential.
- Backups are useful operationally but generally should not be pushed to a public repository. The retired test archive and generated backup files should be excluded or moved to private storage for a public-release branch.
- Keep the gateway bound to loopback unless a deliberate remote-access design is added. The current configuration is not a secure public API deployment.

## 15. Recovery and troubleshooting

Start with the smallest failing layer. Do not immediately kill processes or rewrite config files.

| Symptom | What it means / next check | Safe next action |
|---|---|---|
| `/health/liveliness` is not HTTP 200 | Gateway may be starting, stopped, or failing | `launchctl print ...`; inspect last 80 lines of `gateway.log`; then run `start_gateway.sh` to inspect/recover the LaunchAgent |
| LaunchAgent is missing from `launchctl list` | The plist exists on disk but is not loaded | Confirm port 4000 is free and plist is valid, then bootstrap the exact LaunchAgent; do not start a competing manual server first |
| Port 4000 is occupied by an unexpected PID | Another process may be running a gateway or a different service | Use `lsof -nP -iTCP:4000 -sTCP:LISTEN`; do not `kill -9` an unknown PID |
| `NoCredentialsError: Unable to locate credentials` in LiteLLM | Earlier Bedrock requests attempted an AWS credentials path that did not find credentials | Check the active Bedrock model ID and `AWS_BEARER_TOKEN_BEDROCK` reference; use the recorded successful bearer-token path; distinguish historical log lines from the most recent request |
| `Invalid model ID` from Bedrock | Upstream inference-profile/model ID does not exist for that endpoint/region | Verify provider's exact ID and region; test direct only with the documented bearer token and never print the token |
| OpenCode lists a model but says `Model unavailable` | Discovery does not guarantee provider/model resolution; custom provider namespace/config can be the issue | Check `opencode --version`, the `opencode.json` model key, run `gw-sync-opencode-models`, then inspect the runtime config without sharing secrets |
| OpenCode says `No api key passed in` | OpenCode's running service did not resolve/pass the gateway key | Source `ai-env.sh`, `unset GATEWAY_API_KEY`, restart the OpenCode service via the gateway launcher, retry; this sequence worked in the recorded session |
| OpenCode output is empty for `opencode models` | Could be an issue with the installed CLI output/terminal, not proof that no model exists | Re-run and check exit status; compare with `gw-models` and the `/v1/models` endpoint |
| Model returns HTTP 401/403 | Client master key rejected or upstream provider key/permissions invalid | Identify which layer issued the response; never paste any actual keys when reporting it |
| HTTP 429 or quota error | Upstream provider/model quota may be depleted | Check billing/quota, wait or choose another alias; a fallback only occurs if configured for that alias |
| `gw-models` works but a model call fails | The alias exists, but the upstream route may be broken/unfunded/unsupported | Run `gw-test-model ALIAS` then review the corresponding current log lines |
| Model text response succeeds but coding agent doesn't use tools | Text generation is not equivalent to tool calling | Test tool calling separately and verify provider/model API supports the necessary tool format |
| `ai-env.sh` reports `_ai_env_keys[@]: unbound variable` | It was sourced under macOS Bash 3.2 with `set -u`/nounset active in its caller | Do not source the loader from a nounset-enabled shell script; the fixed installer deliberately avoids `set -u` while sourcing it |
| Zsh reports `no matches found: providers[litellm]` or parses Python as shell | A Python code block was pasted into the shell instead of being run through a Python interpreter | Stop; don't continue pasting the remaining lines. Run Python via a quoted heredoc or install the provided `.py` file |

### Legacy request wiretap

`wiretap.py` remains in the tree as a debugging aid from the earlier VS Code-extension investigation. The old README described it as a proxy on port `4001` that recorded traffic to `/tmp/roo_wiretap.log`. It is **not** in the normal client→gateway request path and should only be used when diagnosing a client that appears not to send a request. Inspect the current script before running it, and review/redact the resulting log before sharing.

### Commands to collect a useful diagnostic bundle

These commands don't print the contents of `.env`:

```bash
GW="$HOME/dev/ai-ops/gateway"
LABEL="com.nitant.litellm-gateway"

echo '=== Health ==='
curl -sS -w '\nHTTP %{http_code}\n' http://127.0.0.1:4000/health/liveliness

echo '\n=== LaunchAgent summary ==='
launchctl print "gui/$(id -u)/$LABEL" 2>&1 | grep -E 'state =|runs =|pid =|last exit code|path =|program ='

echo '\n=== Listener ==='
lsof -nP -iTCP:4000 -sTCP:LISTEN || true

echo '\n=== Recent log tail ==='
tail -n 80 "$GW/gateway.log"
```

Redact local usernames, private paths, prompts, request bodies, and any secrets before sharing the output publicly.

## 16. Current verification status

This table separates observed results from assumptions.

### Verified during the recorded session

- [x] The LaunchAgent plist exists, passes `plutil -lint`, and was registered in the current user's `gui` domain.
- [x] LaunchAgent reported `KeepAlive = true`, `RunAtLoad = true`, `state = running`, and the expected wrapper script.
- [x] LiteLLM health endpoint returned HTTP 200.
- [x] The live authenticated `/v1/models` response contained nine aliases.
- [x] A direct Bedrock Opus inference-profile request with the bearer API token returned HTTP 200.
- [x] LiteLLM `/v1/messages` test for `bedrock-opus` returned `OPUS_WORKING` with HTTP 200.
- [x] LiteLLM `/v1/chat/completions` test for `bedrock-opus` returned `OPENCODE_CHAT_COMPLETIONS_WORKING` with HTTP 200.
- [x] Terminating gateway PID `16874` caused launchd to restart it under PID `17231`; launchd's run count changed to `2`.
- [x] The launchd-aware `start_gateway.sh` reported that the managed gateway was healthy and left it running.
- [x] OpenCode's live catalogue showed all nine generated `opencode/gw-*` aliases.
- [x] After loading the gateway environment, unsetting `GATEWAY_API_KEY`, and restarting the OpenCode service, `opencode run` returned `OPENCODE_GATEWAY_OK` via `opencode/gw-free-workhorse`.
- [x] The user reported that the graphical/IDE harness selected the `bedrock-sonnet` route and worked.
- [x] The migration installer archived and retired the old `agent-lab` test directory without restarting the gateway; the local archive was subsequently removed during the cleanup.

### Not yet verified in the recorded session

- [ ] A complete Mac reboot followed by user login and automatic gateway startup.
- [ ] OpenCode tool calling with a real but harmless terminal command. The smoke test above was proposed, but no result was recorded.
- [ ] Each of the nine upstream model aliases individually, including quota, cost, current model availability, and tool calling.
- [ ] A full real-repository coding run where OpenCode edits code, runs tests, and the human reviews the diff.
- [ ] Full public-GitHub hygiene audit of `.gitignore`, tracked files, commit history, and runtime logs.
- [ ] Log rotation/retention policy for `gateway.log`.
- [ ] Remote access from other devices. Current bind is loopback only, so this is not part of the present verified setup.

## 17. Preparing the project for GitHub

The point of GitHub is to preserve the explanation and allow other people to reproduce the design, not to publish private machine state.

### Good candidates to version

- `gateway/README.md`
- `gateway/config.yaml` (it contains environment-variable references, not secret values, as currently shown)
- `gateway/ai-env.sh`
- `gateway/start_gateway.sh`
- `gateway/wrapper_launchd.sh`
- `gateway/requirements.txt`
- `gateway/bin/` and `gateway/scripts/`
- `gateway/clients/README.md`
- `gateway/docs/` notes, including the chronological build log
- A redacted `.env.example` with placeholders, if you choose to add one

### Keep out of a public repository

- `gateway/.env`
- the real runtime `gateway.log` unless scrubbed and deliberately included as a sanitized sample
- `gateway/venv/`
- user-specific launchd state or plist paths unless converted to a portable template
- backup directories, timestamped backups, and the old test-lab archive unless there is a deliberate reason to publish them
- any key, access token, database password, private request content, or path/user detail you prefer not to reveal

Before the first public push, inspect both the current working tree and the full commit history. A secret committed in the past remains in history even if deleted in a later commit. Rotate it if there is any chance it was exposed.

The engineering history lives in [`docs/02-build-log.md`](docs/02-build-log.md). That file is a reconstructed build diary from the available session records and user-provided command outputs—not a raw, byte-for-byte shell transcript. The gateway's actual runtime log remains `gateway.log`.

## 18. Further reading and engineering history

- [LiteLLM proxy getting started](https://docs.litellm.ai/docs/)
- [LiteLLM proxy model configuration](https://docs.litellm.ai/docs/proxy/configs)
- [LiteLLM model management / `/v1/models`](https://docs.litellm.ai/docs/proxy/model_management)
- [OpenCode V2 provider configuration](https://opencode.ai/v2/docs/providers)
- [OpenCode V2 configuration and environment substitution](https://opencode.ai/v2/docs/config)
- [Engineering build log: problems, decisions, fixes, and verification](docs/02-build-log.md)

Start with the build log when you want to understand **why** the system has its current shape. Use the README when you want to understand **how** to operate it.
