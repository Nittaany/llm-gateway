# AI Development Gateway — Architecture

> **Purpose:** the current system map: what runs locally, how the clients reach it, and what has actually been verified.
> **Last verified snapshot:** 30 October 2026. Update the status table when tests change.

## Mission and design principles

This project provides one locally controlled gateway for several cloud AI providers. Coding clients use a stable local endpoint and model aliases; provider-specific credentials and routing remain behind the gateway.

1. **Ownership:** the gateway and client configuration are managed locally. Providers are replaceable backends.
2. **Cost discipline:** model aliases make it possible to choose lower-cost routes deliberately. A configured free-tier route is not a promise of unlimited or permanently free service.
3. **Trust per step:** tool execution and file changes must remain subject to the permissions and approval controls of the client in use. A text-generation smoke test does not prove safe or successful tool execution.
4. **One source of truth:** `gateway/config.yaml` defines LiteLLM routes. OpenCode's generated catalogue is derived from the live gateway model list.
5. **Local-first network boundary:** LiteLLM binds to `127.0.0.1`; this setup is not exposed to the LAN or public internet.

## Current system map

```text
                         THIS MAC (user session)
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│   OpenCode CLI / TUI                Graphical coding harness         │
│   gateway/bin/gw-opencode           custom provider entry            │
│          │                          │                                │
│          └──────────────┬───────────┘                                │
│                         │                                            │
│                         ▼                                            │
│             LiteLLM gateway: 127.0.0.1:4000                          │
│             OpenAI-compatible API + Anthropic Messages API           │
│                         │                                            │
│       ┌─────────────────┼─────────────────────┐                      │
│       │                 │                     │                      │
│       ▼                 ▼                     ▼                      │
│  config.yaml       .env secrets        optional spend database       │
│  aliases/routes    provider keys       configuration present;       │
│  fallbacks         + master key        end-to-end history check      │
│                                        still pending                 │
│                         │                                            │
│                         ▼ HTTPS                                      │
└─────────────────────────┼───────────────────────────────────────────┘
                          ▼
              Upstream model providers / Bedrock
```

The LiteLLM process is supervised by a macOS **LaunchAgent**. `RunAtLoad` starts it when the user's login session loads the agent; `KeepAlive` asks `launchd` to relaunch it after the process exits. This is user-session startup, not a pre-login system daemon.

## Components

- **LiteLLM gateway** — a local Python service listening at `http://127.0.0.1:4000`. Clients authenticate with `LITELLM_MASTER_KEY`. The gateway translates supported client API formats and routes model aliases to upstream providers.
- **`config.yaml`** — the source of truth for LiteLLM model aliases, provider/model identifiers, credential environment-variable names, and configured fallback relationships.
- **`.env`** — local-only values such as upstream provider credentials and `LITELLM_MASTER_KEY`. It is excluded by Git ignore rules and must never be committed. `.env.example` contains placeholders, not real values.
- **`wrapper_launchd.sh`** — the LaunchAgent's wrapper. It loads the local environment and starts LiteLLM bound to loopback port `4000`.
- **`start_gateway.sh`** — a launchd-aware service controller. Its healthy path checks the managed service and avoids killing an unknown process that happens to occupy port `4000`.
- **OpenCode integration** — `gateway/opencode.json` is the central generated client config. `gateway/bin/gw-sync-opencode-models` refreshes the generated model entries from the live `/v1/models` response. `gateway/bin/gw-opencode` loads the expected gateway environment and launches OpenCode with that central config.
- **Graphical coding harness** — configured as an independent client using the local gateway address, the gateway master key, and a bare LiteLLM alias such as `bedrock-sonnet`. Its provider-specific credentials remain in the gateway `.env` file.
- **Wiretap diagnostic proxy** — `gateway/wiretap.py` can sit between a client and the gateway for request-flow diagnostics. Its current logging records selected metadata, timing, and byte counts; it must not log authorization values, prompt bodies, or response text.
- **Spend database** — PostgreSQL/database settings have been part of the gateway configuration. Full end-to-end verification of historical spend visibility in the UI remains pending; do not treat the dashboard as a verified operational feature until tested.

## Current model aliases

The live `/v1/models` endpoint returned these nine aliases during the 30 October 2026 verification session:

| Alias | Role / provider family |
|---|---|
| `free-workhorse` | Gemini Flash route |
| `premium` | Gemini Pro preview route; configured fallbacks exist |
| `bedrock-sonnet` | Anthropic Claude Sonnet through Amazon Bedrock |
| `bedrock-opus` | Anthropic Claude Opus through Amazon Bedrock |
| `free-openai` | OpenAI GPT-4o mini route |
| `free-anthropic` | Anthropic Claude 3.5 Haiku route |
| `free-kimi` | Moonshot/Kimi route |
| `free-glm` | Z.ai GLM 4.7 Flash route |
| `free-openrouter` | OpenRouter free-catalog route |

A catalogue entry proves only that the gateway advertises an alias. It does **not** prove that the provider key, quota, model availability, tool calling, or fallback behavior is currently healthy. Check the route with a request before relying on it.

## Life of a request (OpenCode example)

1. Launch OpenCode through `gateway/bin/gw-opencode`. The wrapper loads the expected gateway environment and selects `gateway/opencode.json` as the central config.
2. OpenCode selects a generated model entry such as `opencode/gw-free-workhorse`. The generated entry maps back to the bare LiteLLM alias `free-workhorse`.
3. OpenCode sends an authenticated request to the local LiteLLM endpoint.
4. LiteLLM validates the client key against `LITELLM_MASTER_KEY` and resolves the requested alias using `config.yaml`.
5. LiteLLM uses the configured provider credential from the local environment to contact the upstream provider over HTTPS.
6. The response returns through LiteLLM to OpenCode.
7. If the model requests tools, the client may execute them according to its own permission/approval policy. The current successful OpenCode smoke test verified a text response only; tool calling remains unverified.

Fallback relationships are configured in `config.yaml`, but their behavior should be tested with controlled failures before being described as proven.

## Verified status — 30 October 2026

| Area | Status | Evidence / limitation |
|---|---|---|
| LiteLLM service | **Running** | Health endpoint returned HTTP 200 during the session. |
| Local network boundary | **Configured** | Listener binds to `127.0.0.1:4000`; this is not remotely accessible without a separate tunnel or network design. |
| LaunchAgent crash recovery | **Verified** | A controlled `SIGTERM` stopped the gateway process and `launchd` started a replacement. |
| Full reboot/login startup | **Not yet verified** | Must be tested after a natural macOS restart and login. |
| Model catalogue | **Verified** | Nine aliases appeared at `/v1/models`; not all aliases have been tested individually. |
| Bedrock Opus | **Verified** | HTTP 200 through `/v1/messages` and `/v1/chat/completions` in the recorded tests. |
| OpenCode text request | **Verified** | `OPENCODE_GATEWAY_OK` returned through `opencode/gw-free-workhorse` after restarting the OpenCode service with the expected environment loaded. |
| Graphical harness | **User-confirmed** | User reported a working session through `bedrock-sonnet`; raw response capture was not recorded. |
| Tool calling | **Not yet verified** | A text response does not prove the tool-call loop. |
| All provider aliases / fallbacks | **Not yet verified** | Test keys, quotas, current model IDs, and fallback paths individually. |
| Spend history / dashboard | **Pending end-to-end verification** | Database configuration exists, but historical spend visibility has not been fully confirmed. |
| Log rotation | **Not yet implemented/verified** | Define and test a retention policy before treating logs as managed. |

## Repository layout

```text
ai-ops/
├── README.md
└── gateway/
    ├── .env                  # local secrets; never commit
    ├── .env.example          # placeholders only
    ├── config.yaml           # LiteLLM routing source of truth
    ├── opencode.json         # generated central OpenCode config
    ├── ai-env.sh             # shared environment loader
    ├── start_gateway.sh      # launchd-aware controller
    ├── wrapper_launchd.sh    # LaunchAgent wrapper
    ├── wiretap.py            # metadata-only diagnostic proxy
    ├── bin/                  # client entrypoints and helpers
    ├── scripts/              # helper implementations
    ├── clients/README.md
    └── docs/                  # this documentation set
```

The old `agent-lab/` experiment, the former root-level `kb/` directory, and timestamped backup/archive files were removed during the 30 October cleanup. The old task runner is historical context, not part of the current runtime or repository layout.

## Security and operational boundaries

- Keep `.env`, runtime logs, virtual environments, caches, and local LaunchAgent plist files out of Git unless a sanitized, portable template is intentionally created.
- Never expose the gateway by changing its bind address to `0.0.0.0` as a shortcut. Remote use requires an explicit VPN/tunnel, authentication, firewall, and threat-model design.
- Do not kill an unknown listener on port `4000`. Inspect the process and let the launchd-aware controller manage the gateway.
- Do not interpret a listed model alias as evidence that the provider route is working.
- Do not interpret a successful text response as evidence that tool calling, file editing, or autonomous task execution is safe.
- Review the Git index and commit history before publishing. A clean current tree does not remove secrets that may have been committed in earlier history.
