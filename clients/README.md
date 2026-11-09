# Coding Harness Clients — LiteLLM Gateway

This guide explains how client applications connect to the gateway. It intentionally uses the generic term **harness** for the graphical/IDE client.

> **Note:** All paths below are relative to the gateway root directory (where you cloned the repo). Run commands from that directory, or substitute your actual path.

## The rule: clients use the gateway key, not upstream provider keys

The shared source of truth is:

- `gateway/.env` — private gateway and provider credentials
- `gateway/config.yaml` — LiteLLM model aliases and routing rules
- `gateway/opencode.json` — generated OpenCode V2 model catalogue

Do not copy Gemini, Bedrock, OpenAI, Anthropic, Moonshot, Z.ai, or OpenRouter upstream keys into client configuration. The client only needs the actual value of `LITELLM_MASTER_KEY`.

The endpoint currently binds to `127.0.0.1:4000`; these clients must be running on this Mac. It is not a remote/public endpoint.

## OpenCode V2

Use the central config, generated from the live LiteLLM `/v1/models` response. Run OpenCode from the project directory you want it to work on.

If you add the gateway's `bin/` directory to your `PATH`, you can run these from anywhere:

```bash
bin/gw-opencode
bin/gw-opencode models
bin/gw-opencode run \
  --model gateway/free-workhorse \
  "Reply with exactly: OK"
```

The wrapper:

1. loads `gateway/.env` through `ai-env.sh`;
2. removes the known-conflicting `GATEWAY_API_KEY` environment variable;
3. checks the gateway health endpoint and calls `start_gateway.sh` if recovery is needed;
4. sets `OPENCODE_CONFIG` to `gateway/opencode.json`;
5. launches the installed `opencode` command without changing the current working directory.

### Why the model references use `opencode/gw-`

On the OpenCode V2 `2.0.25` version used during this setup, the first custom provider namespace (`litellm/...`) appeared in model discovery but failed to execute with `Model unavailable` and/or `No api key passed in`. The tested compatibility workaround overlays gateway models on OpenCode's existing catalog provider. For example:

- OpenCode selector: `opencode/gw-bedrock-sonnet`
- LiteLLM alias sent upstream: `bedrock-sonnet`

The prefix `gw-` is only a client-side name. `config.yaml` continues to use the bare LiteLLM alias. The sync script contains the current workaround; test it before changing it after an OpenCode upgrade.

### List, sync, and test

```bash
# Show the current LiteLLM aliases
bin/gw-models

# Refresh OpenCode's generated config after changing config.yaml and restarting LiteLLM
bin/gw-sync-opencode-models

# Test the alias through /v1/chat/completions
bin/gw-test-model free-workhorse
bin/gw-test-model bedrock-opus
```

A catalogue entry does not prove provider authentication, quota, price, or tool compatibility. Test a real request. Tool support should be tested separately before using a model for coding operations.

### If OpenCode says `No api key passed in`

The recovery sequence:

```bash
source ai-env.sh >/dev/null
unset GATEWAY_API_KEY
bin/gw-opencode service status
bin/gw-opencode service restart
bin/gw-opencode run \
  --model gateway/free-workhorse \
  "Reply with exactly: OPENCODE_GATEWAY_OK"
```

This is an empirical fix verified on the installed version; the exact internal cause of the old service's missing key was not conclusively isolated.

## Graphical / IDE harness

Configure the GUI client once using a custom provider. Choose the protocol that matches the client.

### OpenAI-compatible API

- **Base URL:** `http://127.0.0.1:4000/v1`
- **API key:** the actual value of `LITELLM_MASTER_KEY`
- **Model ID:** a bare alias from `gw-models`, such as `free-workhorse`, `bedrock-sonnet`, or `bedrock-opus`
- **Usual route:** `/v1/chat/completions`

### Anthropic-compatible API

This route was used for the recorded Sonnet setup:

- **Base URL:** `http://127.0.0.1:4000`
- **API key:** the actual value of `LITELLM_MASTER_KEY`
- **Model ID:** `bedrock-sonnet`
- **Usual route:** `/v1/messages`
- **Anthropic version:** `2023-06-01`

The application may display a provider-prefixed reference such as `new-provider/bedrock-sonnet`; LiteLLM's alias is still `bedrock-sonnet`.

### Copy the gateway key without printing it

Run this from the gateway directory, then paste from the clipboard into the GUI client's API-key field:

```bash
source ai-env.sh >/dev/null
printf %s "$LITELLM_MASTER_KEY" | pbcopy
```

Do not enter the literal text `$LITELLM_MASTER_KEY` into a GUI field—most apps expect the resolved secret value.

The user reported the Sonnet session working, but each new model and tool-use mode should still be smoke-tested before relying on it.

## Security and network boundary

- Keep upstream provider credentials only in `.env`.
- Do not put secret values in this file or any client configuration committed to Git.
- The gateway is bound to loopback. To access it from another device, design and secure a VPN or authenticated TLS reverse proxy first; do not merely bind the gateway to `0.0.0.0` and expose it.
- Do not publish raw runtime logs without reviewing them for request content, paths, usernames, and secrets.
