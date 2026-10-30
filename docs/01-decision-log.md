# 01 — Decision Log (ADR style)

> This file records the choices that shaped the system, the alternatives considered, and the consequences. Older entries are historical decisions; the current implementation and status are described in `00-architecture.md`.

## ADR-001: Hybrid multi-model architecture, not local-only models

- **Context:** The initial research explored a fully offline local agent using Ollama and Goose. The project goal was then clarified: orchestrate free-tier and paid cloud APIs while retaining control over routing and credentials.
- **Decision:** Use a local gateway to route requests to cloud model providers. Local models are not part of the current architecture.
- **Alternatives rejected:** A fully local setup would impose hardware, storage, and model-quality tradeoffs that did not match the goal. A single-vendor cloud product would reduce routing flexibility and ownership.
- **Consequence:** Internet access is required. Provider quotas, terms, availability, and per-model costs remain operational constraints.

## ADR-002: LiteLLM as the gateway layer

- **Context:** Multiple coding clients need one stable endpoint and a shared model catalogue without storing upstream provider keys in each client.
- **Decision:** Run LiteLLM in a dedicated Python virtual environment under `gateway/`, exposing the local API on `127.0.0.1:4000`.
- **Alternatives rejected:** Configuring every client directly against every provider duplicates credentials and configuration. Using a hosted router alone would move important routing control outside this project.
- **Consequence:** One local service must be supervised and maintained. Clients can share model aliases and a gateway master key.

## ADR-003: Cline over Roo Code for the earlier IDE-agent experiment

- **Context:** Roo Code repeatedly hung in its request/send workflow. Wiretap observations and repeated restarts did not show the expected gateway request. Cline, a related extension, was subsequently used as the alternative.
- **Decision:** Stop spending time on the unresolved Roo Code hang and use Cline for that earlier IDE-agent experiment.
- **Alternatives rejected:** Indefinite debugging of a failure with no useful request trace.
- **Consequence:** The incident is retained as a historical debugging lesson. This ADR does not claim that Cline is the currently tested primary client; current verified client integrations are listed in `00-architecture.md`.

## ADR-004: Gemini aliases plus a pinned premium route

- **Context:** Earlier Gemini model identifiers became unavailable, and a `latest` alias did not consistently behave as expected for the desired Pro-class route.
- **Decision:** The gateway configuration used a Flash alias for `free-workhorse` and a pinned Pro preview identifier for `premium`, with fallback routes configured.
- **Alternatives rejected:** Pinning every workhorse model to a numbered model version increases maintenance when providers retire models.
- **Consequence:** The exact provider model IDs and quota behavior must be rechecked against the current `config.yaml` and provider account. A configured premium alias or fallback does not guarantee quota or successful execution.

## ADR-005: Use a macOS LaunchAgent to supervise LiteLLM

- **Context:** Manual startup made the gateway easy to forget and left clients failing when the process stopped.
- **Decision:** Run LiteLLM as a user LaunchAgent with `RunAtLoad` and `KeepAlive`, using `wrapper_launchd.sh` to load the gateway environment before starting the server.
- **Alternatives rejected:** A manually started foreground process has no restart policy. A LaunchAgent is appropriate for a per-user service that starts with the login session.
- **Consequence:** A controlled `SIGTERM` test verified that `launchd` restarted the process. A full macOS reboot/login test remains outstanding. The installed LaunchAgent plist is local and is not currently included as a portable template in the repository.

## ADR-006: PostgreSQL for spend history

- **Context:** Request cost headers alone do not provide durable historical usage records in a dashboard.
- **Decision:** Configure PostgreSQL/database logging for LiteLLM spend data.
- **Alternatives rejected:** Relying only on response headers provides no persistent history. Adding a separate cache such as Redis would not replace a spend ledger.
- **Consequence:** The database configuration and dependencies add operational complexity. End-to-end verification that the expected requests appear in the UI/history is still pending; documentation must not describe that feature as fully proven yet.

## ADR-007: OpenCode as the terminal coding client

- **Context:** The aim was to use a terminal coding client with the project's own gateway aliases. The first experiment paired OpenCode with a separate `agent-lab/` task runner and a duplicate local configuration.
- **Decision:** Keep LiteLLM as the model backend and move OpenCode's generated catalogue and launch helpers into `gateway/`. Use the `gw-opencode` entrypoint so the expected environment and central config are selected consistently.
- **Alternatives rejected:** Maintaining a separate provider catalogue and gateway setup in every experimental repository. Promoting the old task runner's permissive settings into arbitrary projects.
- **Consequence:** OpenCode can be launched from different project directories while sharing the central gateway config. The generated `opencode/gw-*` model entries were verified on the installed OpenCode version recorded in the build log; re-test after OpenCode upgrades.

## ADR-008: Low-cost provider rotation (historical)

- **Context:** The project evaluated provider APIs with free tiers, limited credits, or low-cost routes. Provider policies, free quotas, and catalogue availability changed during the experiment.
- **Decision:** Add multiple provider routes behind LiteLLM aliases rather than binding the client to one provider.
- **Alternatives rejected:** Depending on a single free provider would make the workflow vulnerable to one quota, policy, or availability change.
- **Consequence:** The historical notes about provider prices, credits, and daily limits are not permanent guarantees. The current aliases are those returned by `/v1/models`; actual key validity, quota, model availability, data policy, and tool-call support must be checked per provider. Groq was removed from the configured rotation.

## ADR-009: Teach, execute, and document

- **Context:** Commands were being run faster than the architecture was being understood. This made troubleshooting and ownership harder.
- **Decision:** Explain the purpose of a step, execute it, then record the result in the documentation under `gateway/docs/`.
- **Alternatives rejected:** Move fast and reconstruct the reasoning later.
- **Consequence:** The build log preserves failed attempts as well as successful outcomes. Historical notes should be marked as historical when the implementation changes.

## ADR-011: Keep the working project under one development root

- **Context:** Earlier files and experiments were spread across several home-directory locations.
- **Decision:** Consolidate the current project under `~/dev/ai-ops/`, with runtime code and documentation under `gateway/`.
- **Alternatives rejected:** Keeping multiple disconnected gateway, knowledge-base, and task-lab directories.
- **Consequence:** Python virtual environments are derived artifacts and should be recreated from `requirements.txt` after relocation. The previous `kb/` directory and separate `agent-lab/` directory are no longer part of the current tree.

## ADR-012: Keep interactive TUI work separate from the old autonomous task-runner experiment

- **Context:** An early experiment ran a task script from inside the OpenCode TUI, creating nested-agent behavior and shell timeout issues. Running the script from a plain terminal avoided that specific problem.
- **Decision:** Treat OpenCode's interactive TUI and one-shot `opencode run` command as distinct usage modes. Do not nest an agent inside another agent's shell tool without a clear reason.
- **Alternatives rejected:** Increasing timeouts without addressing the nested execution model.
- **Consequence:** The learning remains useful, but the old `run_harness.sh` task runner and its `agent/runs` branch workflow were retired with `agent-lab/`. They are not current operational commands.

## ADR-013: Gateway-centric configuration and clean repository layout

- **Context:** The standalone `agent-lab/` experiment introduced a second OpenCode configuration and permissive edit/bash settings. Timestamped backups also accumulated in the working tree.
- **Decision:** Keep model routing in LiteLLM, put generated OpenCode configuration and reusable helpers under `gateway/`, and keep project documentation in `gateway/docs/`.
- **Alternatives rejected:** Duplicate provider catalogues in every test repository; universalizing the old task runner's permissions; keeping abandoned backup files in the live source tree.
- **Consequence:** The `agent-lab/` directory and its archive were removed. The separate `kb/` directory and timestamped backup files were also removed during the 30 October 2026 cleanup. Historical events remain documented here and in the build log.

## ADR-014: Keep the gateway bound to loopback

- **Context:** The current gateway is intended for local coding clients on the same Mac. Remote access introduces a different authentication and network-security problem.
- **Decision:** Bind LiteLLM to `127.0.0.1:4000` and do not expose it directly to a LAN or public interface.
- **Alternatives rejected:** Binding to `0.0.0.0` as a shortcut for remote access.
- **Consequence:** Other devices cannot connect directly to this loopback endpoint. Remote access requires a separately designed VPN or tunnel, firewall rules, and access controls.
