# LiteLLM AI Gateway

> One local gateway. All your AI providers. Every coding client.

A plug-and-play AI provider gateway for macOS developers. Connect multiple AI providers (Gemini, Bedrock, OpenAI, Anthropic, and more) through one endpoint, then point any coding tool at `http://127.0.0.1:4000`.

```text
  Your AI clients                     Your providers
  ──────────────                      ──────────────
  OpenCode CLI ─┐                ┌─── Google Gemini
  Cursor        ─┤                ├─── Amazon Bedrock
  Claude Code   ─┼── :4000 ──────┼─── OpenAI
  Windsurf      ─┤   gateway      ├─── Anthropic
  Any OpenAI-   ─┘                ├─── Moonshot / Kimi
  compatible                      ├─── Z.ai / GLM
  client                          └─── OpenRouter
```

## Quick start

```bash
git clone https://github.com/Nittaany/llm-gateway.git
cd llm-gateway
./setup.sh
```

The setup wizard will:
1. Check that you have macOS + Python 3.9+
2. Create a virtual environment and install LiteLLM
3. Ask which providers you have API keys for
4. Generate your `.env`, LaunchAgent, and start the gateway
5. Sync your model catalogue for OpenCode (if installed)

**That's it.** Your gateway is running as a background service.

## Contents

- [What you get](#what-you-get)
- [Daily use](#daily-use)
- [Model catalogue](#model-catalogue)
- [Connecting clients](#connecting-clients)
- [Add or remove a model](#add-or-remove-a-model)
- [Service management](#service-management)
- [Repository layout](#repository-layout)
- [Environment variables](#environment-variables)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Further reading](#further-reading)

## What you get

| Feature | How |
|---|---|
| **One credential boundary** | Provider keys stay in `.env`; clients use one gateway key |
| **One model catalogue** | Aliases like `free-workhorse`, `bedrock-sonnet` in `config.yaml` |
| **Multiple clients** | Any OpenAI-compatible or Anthropic-compatible client works |
| **Smart routing** | Retries, fallbacks, in-memory caching — all in the gateway |
| **Background service** | macOS `launchd` starts and supervises the gateway automatically |
| **Crash recovery** | Gateway restarts itself if the process exits |

### What this is not

- Not a cloud-hosted/public gateway — it binds to `127.0.0.1` (localhost only).
- Not a guarantee that every model is free or always available — provider quotas and billing vary.
- Not a substitute for reviewing AI-generated code changes.

## Daily use

The gateway starts automatically when you log in (via LaunchAgent). No manual startup needed.

```bash
# Check gateway health
curl -s http://127.0.0.1:4000/health/liveliness

# List available model aliases
bin/gw-models

# Test a model
bin/gw-test-model free-workhorse

# Launch OpenCode through the gateway (from any project directory)
bin/gw-opencode

# Headless OpenCode request
bin/gw-opencode run --model opencode/gw-free-workhorse "Reply with: OK"
```

## Model catalogue

| Alias | Route | Provider |
|---|---|---|
| `free-workhorse` | `gemini/gemini-flash-latest` | Google Gemini |
| `premium` | `gemini/gemini-3.1-pro-preview` | Google Gemini |
| `bedrock-sonnet` | `bedrock/global.anthropic.claude-sonnet-4-6` | Amazon Bedrock |
| `bedrock-opus` | `bedrock/au.anthropic.claude-opus-4-6-v1` | Amazon Bedrock |
| `free-openai` | `openai/gpt-4o-mini` | OpenAI |
| `free-anthropic` | `anthropic/claude-3-5-haiku-latest` | Anthropic |
| `free-kimi` | `moonshot/moonshot-v1-8k` | Moonshot |
| `free-glm` | `zai/glm-4.7-flash` | Z.ai |
| `free-openrouter` | `openrouter/nvidia/nemotron-3-ultra-550b-a55b:free` | OpenRouter |

Aliases with empty API keys in `.env` are exposed but won't work until you add the key and restart.

### Routing rules

- `premium` falls back to → `free-workhorse` → `free-glm`
- `free-workhorse` falls back to → `free-glm`
- 2 retries, 5-second delay between retries
- In-memory response cache enabled
- `drop_params: true` — unsupported parameters are silently dropped

## Connecting clients

### Any OpenAI-compatible client (Cursor, Windsurf, etc.)

| Setting | Value |
|---|---|
| **Base URL** | `http://127.0.0.1:4000/v1` |
| **API key** | The value of `LITELLM_MASTER_KEY` from your `.env` |
| **Model** | Any alias from the catalogue (e.g. `free-workhorse`) |

### Anthropic-compatible client

| Setting | Value |
|---|---|
| **Base URL** | `http://127.0.0.1:4000` |
| **API key** | Your `LITELLM_MASTER_KEY` |
| **Model** | e.g. `bedrock-sonnet` |
| **Anthropic version** | `2023-06-01` |

### Copy the gateway key to clipboard

```bash
source ai-env.sh >/dev/null
printf '%s' "$LITELLM_MASTER_KEY" | pbcopy
```

### OpenCode

The `bin/gw-opencode` wrapper handles environment, health checks, and config. Models appear as `opencode/gw-<alias>`.

```bash
bin/gw-opencode                                          # interactive TUI
bin/gw-opencode run --model opencode/gw-bedrock-sonnet "Hello"  # headless
bin/gw-sync-opencode-models                              # refresh model list
```

## Add or remove a model

### Add

1. Add the provider key to `.env` (if new provider)
2. Add a model entry to `config.yaml`:
   ```yaml
   - model_name: my-alias
     litellm_params:
       model: provider/model-id
       api_key: os.environ/MY_API_KEY
   ```
3. Validate: `./venv/bin/python3 -c 'import yaml; yaml.safe_load(open("config.yaml")); print("OK")'`
4. Restart: `launchctl kickstart -k "gui/$(id -u)/$(cat .launchd-label)"`
5. Test: `bin/gw-test-model my-alias`
6. Sync OpenCode: `bin/gw-sync-opencode-models`

### Remove

1. Delete its block from `config.yaml` and any fallback references
2. Remove its key from `.env` only if no other route uses it
3. Restart the gateway and run `bin/gw-sync-opencode-models`

## Service management

```bash
LABEL="$(cat .launchd-label)"

launchctl print "gui/$(id -u)/$LABEL"                    # status
launchctl kickstart -k "gui/$(id -u)/$LABEL"             # restart
lsof -nP -iTCP:4000 -sTCP:LISTEN                         # what owns port 4000
tail -f gateway.log                                       # watch logs
./start_gateway.sh                                        # health-check + auto-recover
```

The controller (`start_gateway.sh`) refuses to kill unrelated processes on port 4000 and asks launchd to restart unhealthy managed instances.

## Repository layout

```text
llm-gateway/
├── setup.sh               # First-time setup wizard
├── uninstall.sh            # Remove background service
├── config.yaml             # Model aliases + routing rules
├── .env.example            # Template for provider credentials
├── .env                    # Your private keys (git-ignored)
├── ai-env.sh              # Shared .env loader / status check
├── start_gateway.sh        # launchd-aware health + recovery controller
├── wrapper_launchd.sh      # The command launchd actually runs
├── opencode.json           # Generated OpenCode V2 config (git-ignored backups)
├── requirements.txt        # Python dependencies
├── gateway.log             # Runtime log (git-ignored)
├── .launchd-label          # Auto-generated service label (git-ignored)
├── bin/
│   ├── gw-opencode         # Launch OpenCode through the gateway
│   ├── gw-models           # List current model aliases
│   ├── gw-sync-opencode-models  # Regenerate OpenCode model list
│   └── gw-test-model       # Smoke-test one alias
├── scripts/
│   ├── sync_opencode_models.py  # Live catalogue → opencode.json
│   └── test_model.py            # Chat Completions smoke test
├── clients/
│   └── README.md           # Per-client setup notes
├── docs/
│   ├── 00-architecture.md  # System design
│   ├── 01-decision-log.md  # Why things are the way they are
│   ├── 02-build-log.md     # Chronological build history
│   ├── 03-glossary.md      # Terms and definitions
│   └── 04-recipes.md       # Common tasks and workflows
└── venv/                   # Python virtual environment (git-ignored)
```

## Environment variables

All credentials live in `.env` (never committed). The `.env.example` file documents every supported variable.

| Variable | Required? | Used by |
|---|---|---|
| `LITELLM_MASTER_KEY` | **Yes** | Gateway auth — every client sends this |
| `GEMINI_API_KEY` | If using Gemini models | `free-workhorse`, `premium` |
| `AWS_BEARER_TOKEN_BEDROCK` | If using Bedrock | `bedrock-sonnet`, `bedrock-opus` |
| `AWS_REGION` | Defaults to `ap-southeast-2` | Bedrock region |
| `OPENAI_API_KEY` | If using OpenAI | `free-openai` |
| `ANTHROPIC_API_KEY` | If using Anthropic | `free-anthropic` |
| `MOONSHOT_API_KEY` | If using Kimi | `free-kimi` |
| `ZAI_API_KEY` | If using Z.ai | `free-glm` |
| `OPENROUTER_API_KEY` | If using OpenRouter | `free-openrouter` |
| `DATABASE_URL` | Optional | PostgreSQL spend tracking (requires prisma) |

Missing optional provider keys simply disable those model routes — the gateway still starts.

## Troubleshooting

### Gateway won't start

```bash
# Check what's on port 4000
lsof -nP -iTCP:4000 -sTCP:LISTEN

# Read recent logs
tail -n 50 gateway.log

# Search for errors
grep -Ei 'ERROR|Exception|Traceback|failed' gateway.log | tail -n 20

# Use the controller (it diagnoses and recovers)
./start_gateway.sh
```

### "Port 4000 is occupied by an unmanaged process"

Another process (maybe a manually started LiteLLM) owns the port. Find and stop it:

```bash
lsof -nP -iTCP:4000 -sTCP:LISTEN     # identify the PID
kill <PID>                             # stop it
./start_gateway.sh                     # let launchd take over
```

### Model returns errors but the gateway is healthy

The gateway is up, but the upstream provider rejected the request:

```bash
# Verify the key is set
source ai-env.sh

# Test the specific model
bin/gw-test-model <alias>

# Check the log for provider error details
grep '<alias>' gateway.log | tail -n 10
```

Common causes: empty API key in `.env`, expired key, quota exceeded, model name changed upstream.

### Config changes not taking effect

LiteLLM loads `config.yaml` at startup. After editing, restart:

```bash
launchctl kickstart -k "gui/$(id -u)/$(cat .launchd-label)"
```

### OpenCode says "No api key passed in"

```bash
source ai-env.sh >/dev/null
unset GATEWAY_API_KEY
bin/gw-opencode
```

See `clients/README.md` for the full recovery sequence.

## Uninstall

```bash
./uninstall.sh
```

This stops the background service, removes the LaunchAgent plist, and optionally cleans up `venv/`, `.env`, and logs. The repository files remain — delete the directory to fully remove.

## Further reading

| Document | What's inside |
|---|---|
| `docs/00-architecture.md` | System design and component relationships |
| `docs/01-decision-log.md` | Why choices were made |
| `docs/02-build-log.md` | Full chronological build history |
| `docs/03-glossary.md` | Terms, definitions, and conventions |
| `docs/04-recipes.md` | Step-by-step common tasks |
| `clients/README.md` | Per-client setup: OpenCode, Cursor, IDE harnesses |
| [LiteLLM docs](https://docs.litellm.ai) | Upstream gateway documentation |

---

**License:** MIT

