# 03 — Glossary

> Plain-language explanations of the terms used in this project. Terms are grouped by topic.

## Python and packaging

- **Python virtual environment (`venv`)** — a project-local Python installation area. Packages installed there are separated from system Python and other projects. It is disposable and can be rebuilt from `requirements.txt`.
- **pip** — Python's package installer. `pip install 'litellm[proxy]'` installs LiteLLM with the dependencies for its proxy/server features.
- **`python -m module`** — runs a module using the selected Python interpreter. It helps ensure a tool uses the intended interpreter and virtual environment.
- **`py_compile`** — asks Python to compile a source file to check syntax without running the program's main behavior.

## APIs and the gateway

- **API key** — a secret string used to authenticate to a service. Treat it like a password; do not paste it into logs, screenshots, source files, or public documentation.
- **Gateway master key** — the client-facing key (`LITELLM_MASTER_KEY`) accepted by the local LiteLLM gateway. It is different from the upstream provider keys stored in `.env`.
- **LiteLLM proxy/gateway** — a local API server that accepts supported standard request formats and routes them to provider-specific APIs. It can provide aliases, fallback configuration, retries, and usage/cost logging.
- **OpenAI-compatible API** — a common request format used by many AI clients, such as `POST /v1/chat/completions`. Compatibility does not imply every provider feature or tool-call behavior is identical.
- **Anthropic Messages API** — an API format used by Anthropic-compatible clients, including the `/v1/messages` path exposed by this gateway.
- **Model alias** — a stable project-defined name such as `bedrock-opus` or `free-workhorse`. LiteLLM maps it to a provider/model identifier in `config.yaml`.
- **Model catalogue** — the list of model identifiers a client can select. An alias appearing in `/v1/models` or a client picker proves discovery, not that the provider can currently answer a request.
- **Fallback chain** — an ordered set of alternate routes configured for a model. It must be tested with controlled failures before claiming that the fallback works in practice.
- **Rate limit (`429`)** — a provider response indicating that a request or account has reached a usage limit. Free-tier limits and eligibility can change.
- **Streaming / SSE** — a response delivered in multiple chunks rather than one complete block. Clients can display partial output as it arrives.
- **Tokens / context window** — models process text in token units. The context window limits how much input, conversation history, and output a request can contain.
- **Tool calling** — a model response that asks the client to run an action, such as reading a file or executing a command. The client controls whether and how the action runs. A successful text response is not a tool-calling test.
- **HITL (human-in-the-loop)** — a design where a person reviews or approves consequential agent actions instead of allowing the agent to make every change unattended.
- **MCP (Model Context Protocol)** — a protocol for connecting AI clients to external tools and data sources. It is not required for the current LiteLLM gateway path.

## Files and configuration

- **YAML** — a human-readable configuration format where indentation and structure matter. `gateway/config.yaml` holds the LiteLLM routes.
- **`.env` file** — a local text file containing `NAME=value` entries for secrets and environment settings. The actual file must stay local and must never be committed.
- **`.env.example`** — a safe template containing placeholder values. It documents required variable names without containing working credentials.
- **Environment variable** — a named value a process inherits from its launching environment, such as `GEMINI_API_KEY` or `LITELLM_MASTER_KEY`.
- **`.gitignore`** — rules telling Git which files and directories should not be tracked, such as `.env`, virtual environments, caches, and runtime logs.
- **Generated configuration** — a file produced by a script from a source of truth. `gateway/opencode.json` is generated from the live gateway model catalogue; it should not be treated as the master model catalogue.

## Git and review

- **Git** — a version-control system that records repository snapshots.
- **Commit** — a named snapshot of staged changes.
- **Branch** — a separate line of development. The old experimental `agent/runs` branch belonged to the retired task-runner experiment and is not part of the current operating procedure.
- **Staging area / index** — the set of changes selected for the next commit. `git diff --cached` shows what is staged.
- **Diff** — a line-by-line comparison showing what changed. Reviewing the diff is a key safety step before committing agent-written or scripted changes.
- **Git history** — prior commits remain in repository history even after a file is deleted. A public-repository audit must consider history as well as the current working tree.

## macOS service management

- **`launchd`** — macOS's service and process manager.
- **LaunchAgent** — a `launchd` job associated with a user's login session. It normally starts when that user logs in; it is not the same as a system daemon that starts before login.
- **plist** — an XML property-list file describing a launchd job, including its label and the program it runs.
- **`RunAtLoad`** — a launchd setting that starts the job when it is loaded.
- **`KeepAlive`** — a launchd setting that asks launchd to keep the job running and relaunch it after it exits.
- **`launchctl`** — the command-line tool used to inspect, bootstrap, stop, and restart launchd jobs.
- **`SIGTERM`** — a process-termination signal used in the recorded gateway recovery test. The operating system delivers the signal; launchd then restarted the gateway process.
- **Wrapper script** — a script run by the LaunchAgent to prepare the environment, load `.env` values, and then execute LiteLLM.

## Databases and spend tracking

- **PostgreSQL** — a relational database server. LiteLLM can use it to persist request and spend records.
- **Database / table / row** — a database contains tables; tables contain rows of structured data.
- **`database_url`** — a connection string that tells an application where its database is located and how to connect.
- **Prisma** — a database client/schema tool used by LiteLLM components. Some installations require generated client artifacts as part of setup.
- **Spend history** — durable request usage and cost records. In this project, database configuration exists, but end-to-end visibility in the dashboard is still a verification item.

## Diagnostics and reliability

- **Wiretap proxy** — a local forwarding proxy that lets a developer observe request metadata and timing while a client talks to the gateway. The current version intentionally avoids logging authorization headers, prompt bodies, and response text; it is not a byte-for-byte content recorder.
- **`lsof`** — a macOS/Unix command that can show which process owns a network socket, such as the listener on port `4000`.
- **Health endpoint** — a lightweight endpoint used to check whether the gateway process is responding. HTTP 200 means the health endpoint responded; it does not prove every model route works.
- **Crash recovery test** — a controlled process termination used to verify that launchd starts a replacement process. It is distinct from a full reboot/login test.
- **Log rotation** — a policy that archives, limits, or deletes old log files. A log file existing does not mean a retention policy is configured.

## OpenCode terms

- **TUI** — terminal user interface. OpenCode's interactive mode runs inside the terminal.
- **Headless / one-shot run** — running a coding client from a command without opening its interactive interface, for example `gw-opencode run ...`.
- **`gw-opencode`** — this project's launcher for OpenCode. It selects the gateway-owned config and loads the expected environment so the client can authenticate to LiteLLM.
- **`opencode/gw-*` model entry** — a generated OpenCode-side model name that maps to a bare LiteLLM alias. The `gw-` part is a client-side namespace, not a second provider.
