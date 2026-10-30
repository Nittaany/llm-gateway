# AI Ops Gateway — Chronological Build and Incident Log

> **Project:** `~/dev/ai-ops`
>
> **Primary component:** `gateway/` (LiteLLM on macOS)
>
> **Record date:** 30 October 2026
>
> **Purpose:** preserve what happened during setup, what errors were observed, which changes were made, what was proven by tests, and what remains open.

This is an **engineering diary reconstructed from the project README, uploaded file snapshots, terminal output pasted during the session, and the subsequent successful test results**. It is not a verbatim capture of every shell command ever run; when a precise timestamp or root cause was not demonstrated, this log says so. It contains no API key values.

The runtime log is a separate file: `gateway/gateway.log`. That file records LiteLLM process output and request errors; this Markdown file records the human explanation and sequence of decisions.

## Executive summary

The project started as a personal multi-provider LiteLLM gateway plus a separate experimental coding-task harness. The operational goal evolved into a central gateway that is managed by macOS `launchd`, with multiple coding harnesses consuming a common alias catalogue and key.

By the end of the recorded session:

- LiteLLM was listening on `127.0.0.1:4000`.
- The LaunchAgent was loaded with `KeepAlive = true` and `RunAtLoad = true`.
- A controlled process termination proved that launchd restarted LiteLLM.
- Nine model aliases were listed by the live `/v1/models` endpoint.
- Bedrock Opus worked through the LiteLLM Anthropic Messages API and Chat Completions API.
- OpenCode was connected using a central gateway-owned config and the working model reference `opencode/gw-free-workhorse`.
- The GUI/IDE harness was configured for `bedrock-sonnet`; the user reported it working.
- The experimental `agent-lab/` directory was archived during migration and removed from the live tree. The temporary archive and other timestamped backups were subsequently deleted during the 30 October cleanup.
- The gateway service was not restarted by the migration installer.

Open items: test OpenCode tool calling, check each provider alias individually, complete a real reboot/login test, establish log rotation, and audit the repository for public GitHub hygiene.

---

## System context and pieces

### Project layout before the gateway-centric migration

```text
ai-ops/
├── agent-lab/             # experimental task runner + OpenCode config
├── gateway/               # LiteLLM, credentials, startup/service scripts
└── kb/                    # architecture, decisions, build log, glossary, recipes
```

`agent-lab/` contained `opencode.json`, `run_harness.sh`, `TASKS.md`, `tasks.py`, `test_tasks.py`, and some pytest cache files. Its runner loaded gateway keys, switched to an `agent/runs` branch, selected the first unchecked task, invoked `opencode run`, instructed it to run pytest, tick the task, and commit. Its local OpenCode config included `edit: allow` and `bash: allow`. This was useful as a contained experiment but was not an appropriate universal policy for arbitrary real code repositories.

### Current layout after the 30 October cleanup

```text
ai-ops/
├── README.md
└── gateway/
    ├── .env                         # local only; never publish
    ├── .env.example                 # placeholders only
    ├── config.yaml                  # LiteLLM route source of truth
    ├── opencode.json                # generated central OpenCode config
    ├── ai-env.sh                    # shared environment loader
    ├── start_gateway.sh             # launchd-aware controller
    ├── wrapper_launchd.sh           # LaunchAgent wrapper
    ├── wiretap.py                   # metadata-only diagnostic proxy
    ├── bin/                         # client entrypoints and utilities
    ├── scripts/                     # catalogue sync and smoke-test scripts
    ├── clients/README.md
    └── docs/                        # architecture, decisions, build log, glossary, recipes
```

There is no current `backups/` directory, separate root-level `kb/` directory, or live `agent-lab/` directory. The temporary migration archive was later removed during cleanup.

### Architecture decision

**One gateway; independent clients; provider keys stay behind the gateway.** Clients use `LITELLM_MASTER_KEY`. LiteLLM routes aliases to upstream providers using keys from `.env`. OpenCode's model catalogue is generated from the live API rather than maintained by hand. The GUI/IDE harness has its own saved custom provider entry.

The service is currently local-only (`127.0.0.1:4000`). This session did not expose it to a LAN or public interface.

---

## Chronology and incident entries

## Entry 1 — Pre-existing gateway and model catalogue

**Starting point:** the project already had LiteLLM installed in `gateway/venv`, `config.yaml`, `.env`, `ai-env.sh`, `start_gateway.sh`, `wrapper_launchd.sh`, `requirements.txt`, `gateway.log`, `wiretap.py`, and a LaunchAgent plist on disk.

The gateway already had nine model aliases. In the initial version of the config, the Bedrock model strings were not the final working identifiers; Entry 2 records the correction. The **final/current route set** at the end of this session was:

1. `free-workhorse` → `gemini/gemini-flash-latest`
2. `premium` → `gemini/gemini-3.1-pro-preview`
3. `bedrock-sonnet` → `bedrock/global.anthropic.claude-sonnet-4-6`
4. `bedrock-opus` → `bedrock/au.anthropic.claude-opus-4-6-v1`
5. `free-openai` → `openai/gpt-4o-mini`
6. `free-anthropic` → `anthropic/claude-3-5-haiku-latest`
7. `free-kimi` → `moonshot/moonshot-v1-8k`
8. `free-glm` → `zai/glm-4.7-flash`
9. `free-openrouter` → `openrouter/nvidia/nemotron-3-ultra-550b-a55b:free`

`free-groq` was commented out. The presence of an alias was never treated as proof of active provider quota or successful tool calls.

Router rules were configured: `premium` falls back to `free-workhorse` then `free-glm`; `free-workhorse` falls back to `free-glm`; two retries and a five-second retry delay. Local in-memory caching and `drop_params: true` were enabled. The master key and database URL were environment references.

**Decision:** retain LiteLLM as the one routing/backend layer rather than configuring every client directly against each upstream API.

## Entry 2 — Bedrock model identifier correction

**Problem:** a direct Bedrock request using an invalid model/inference-profile identifier returned HTTP 400 (`invalid model ID`). One trial used an `apac...` identifier that was not accepted by the selected runtime endpoint/region.

**Investigation:** the Bedrock bearer API key was checked without printing its value. Both `AWS_BEARER_TOKEN` and `AWS_BEARER_TOKEN_BEDROCK` were present in the user's environment, with the latter referenced by the current `config.yaml`. The observed bearer token length was 132 characters; the actual token was not added to this log.

**Fix/test:** a direct `curl` request to the Bedrock runtime in `ap-southeast-2`, targeting the accepted `au.anthropic.claude-opus-4-6-v1` profile and using the bearer token, returned HTTP 200 and the intended response text. The active gateway config was set to:

```yaml
- model_name: bedrock-sonnet
  litellm_params:
    model: bedrock/global.anthropic.claude-sonnet-4-6
    api_key: os.environ/AWS_BEARER_TOKEN_BEDROCK
    aws_region_name: ap-southeast-2

- model_name: bedrock-opus
  litellm_params:
    model: bedrock/au.anthropic.claude-opus-4-6-v1
    api_key: os.environ/AWS_BEARER_TOKEN_BEDROCK
    aws_region_name: ap-southeast-2
```

**Result:** this established a working direct Bedrock route for Opus and the configuration used for Sonnet. It did not, by itself, prove every harness protocol was working.

## Entry 3 — Early environment/authentication errors

The gateway log contained older failures such as:

```text
botocore.exceptions.NoCredentialsError: Unable to locate credentials
INFO: ... POST /v1/messages ... 500 Internal Server Error
```

These errors were observed in older requests before later successful calls. LiteLLM had attempted a credential/signing path that did not find credentials. We did not conclusively prove that every older error had one identical root cause, so the log should not be read as evidence that the final running process was still failing.

The environment loader `ai-env.sh` was enhanced earlier to parse `.env` entries as literal `KEY=value` lines, trim surrounding whitespace, remove matching outer quotes, and report which variables were populated without printing their values. It also sets a default `AWS_REGION` of `ap-southeast-2` if none is supplied.

The active gateway wrapper separately parses `.env`, exports the values for the gateway process, and explicitly sets the Bedrock region. The config uses `AWS_BEARER_TOKEN_BEDROCK` for the Bedrock aliases. Do not infer that a value is used just because another variable with a similar name exists.

Other warning messages in historical log regions included the router's auto-router baseline observation not initializing and LiteLLM stripping unsupported `output_config` fields for an Opus request. These warning lines did not themselves equal the `NoCredentialsError` that caused the observed HTTP 500s. `gateway.log` also contained older paths such as `$HOME/ai-gateway/`; those entries predate the current `~/dev/ai-ops/gateway` layout. Use timestamps and paths to distinguish historical output from the current process.

## Entry 4 — LaunchAgent file existed but service was not loaded

**Symptom:** the LaunchAgent plist existed at `~/Library/LaunchAgents/<LAUNCHD_LABEL>.plist`, and the gateway health endpoint answered HTTP 200, but `launchctl list | grep -F <LAUNCHD_LABEL>` returned `NOT FOUND`. A Python process (PID `16211` in one check) was listening on port `4000`.

**Meaning:** a plist on disk does not mean the job is registered with launchd. The listener at that moment was likely a manually started LiteLLM process rather than a loaded LaunchAgent-owned service; this followed the project's then-current manual startup workflow.

**Action:** after checking the plist, its command, and the port state, the service was bootstrapped into the current user's GUI domain:

```bash
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/<LAUNCHD_LABEL>.plist"
```

**Initial transient:** immediately after the bootstrap, a health check initially returned curl error 7 / HTTP 000 because LiteLLM had not finished coming up yet. The following log entries showed startup progressing, with Prisma migrations reporting “No pending migrations to apply,” followed by “Application startup complete” and Uvicorn listening on `http://127.0.0.1:4000`.

**Observed running process:** PID `16874`; launchd reported `state = running`, `runs = 1`, and `last exit code = (never exited)`.

**Decision:** use launchd as the single supervisor. Avoid simultaneously running a manual LiteLLM server and a LaunchAgent-owned server.

**Additional startup warnings recorded:** LiteLLM also logged `psycopg is not installed; skipping the invalid index check` and a Prisma client warning, `connect(): 'Prisma' object has no attribute '_Prisma__engine'`. Despite these warnings, the same startup reached `Application startup complete` and Uvicorn listened on port 4000. The warnings were not fixed during this work; they are documented as non-fatal in the observed run, not declared harmless for every possible operation. The gateway also logged a `trusted_proxy_ranges` warning for the Admin UI rate-limit policy. No reverse proxy was part of this local-only setup.

## Entry 5 — Historical startup script was unsafe for a managed service

The earlier `start_gateway.sh` was a foreground launcher. If port 4000 was occupied, it attempted to `launchctl bootout` the gateway LaunchAgent and then force-killed the process that owned the port. This is dangerous when the intended design is “launchd always owns the gateway,” because a routine startup command can disable the very supervisor expected to recover the process.

A timestamped copy of a prior script was retained at:

```text
gateway/start_gateway.sh.bak.20261030-034145
```

A later backup made before the launchd-aware controller was installed is:

```text
gateway/start_gateway.sh.backup-20261030-042532
```

The old README also contained a port-conflict workaround using `lsof -ti :4000 | xargs kill; pkill -f litellm`. That blanket kill advice is superseded and should not be used: it can stop an unrelated process or the very service that launchd is expected to manage.

**Fix:** replace the foreground/takeover behavior with a launchd-aware controller that:

- validates the plist;
- checks whether the LaunchAgent is loaded;
- compares the PID launchd reports against the listener on port 4000;
- exits successfully if the managed gateway is already healthy;
- bootstraps the plist if it is not loaded and the port is free;
- asks launchd to restart its own service if unhealthy;
- refuses to kill an unknown/unmanaged listener.

**Observed result:** running `./start_gateway.sh` later printed `OK: launchd-managed gateway is already healthy (PID 17231).` This verifies the healthy/no-op path of the new controller.

## Entry 6 — Proving process-crash recovery

A controlled test identified the gateway listener as PID `16874`, sent it `SIGTERM`, and waited for a replacement process to own port 4000 and answer the health endpoint.

The command output was:

```text
Current gateway PID: 16874
Sending SIGTERM to test launchd recovery...
PASS: launchd restarted the gateway.
Previous PID: 16874
New PID:      17231
state = running
runs = 2
pid = 17231
```

**Result:** process-crash recovery was genuinely demonstrated. `KeepAlive = true` was not merely assumed from the plist; a terminated gateway process was replaced automatically.

**Limit:** this test does not prove startup after a full Mac reboot and login. That remains an explicit pending test.

The subsequent controller check was consistent with this result:

```text
OK: launchd-managed gateway is already healthy (PID 17231).
```

This validates the controller's healthy/no-op path too; it does not exercise a full reboot.

## Entry 7 — Bedrock Opus through LiteLLM

A request to `http://127.0.0.1:4000/v1/messages` used `x-api-key: $LITELLM_MASTER_KEY`, `anthropic-version: 2023-06-01`, model `bedrock-opus`, and a short fixed-response prompt.

**Observed response:** HTTP 200 and `OPUS_WORKING`.

This was important because it crossed the client-to-gateway authentication boundary and the gateway-to-Bedrock model route. It also established the Anthropic-compatible Messages API was working for Opus at that time.

A later `/v1/chat/completions` request with model `bedrock-opus` returned HTTP 200 and `OPENCODE_CHAT_COMPLETIONS_WORKING`. That established the OpenAI-compatible Chat Completions path for the same alias as well.

## Entry 8 — OpenCode test harness inspected

The earlier gateway README also records a separate VS Code-extension incident: Roo Code was removed after an unresolved send-pipeline hang, while Cline (a related extension in the same family) reportedly worked with the same gateway setup. The file `wiretap.py` was retained as a request-metadata diagnostic proxy, historically described as listening on port `4001` and writing `/tmp/roo_wiretap.log`. Its current logging excludes authorization headers and message/response content; it records selected metadata, timing, and byte counts. This was background from prior project work, not a new test performed in the present session. The key lesson is that an extension can fail before it sends a request, even when the gateway itself is healthy; a successful direct `curl` and a healthy `/health/liveliness` endpoint do not prove that every client UI works.

The temporary `agent-lab/opencode.json` was very small:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "edit": "allow",
    "bash": "allow"
  }
}
```

It had no gateway provider configuration. `run_harness.sh` loaded values from gateway `.env`, unset `GATEWAY_API_KEY`, switched to `agent/runs`, read the first unchecked task, invoked `opencode run`, asked for one function implementation plus pytest, ticked a checkbox, and committed changes. `TASKS.md` had three small tasks (word count, palindrome, running average), all marked complete by the time of the uploaded snapshot. The code and tests showed that this was a test bed, not the desired central configuration location.

**Design decision:** move ongoing harness connectivity/configuration into `gateway/`, not into a dedicated task-lab directory. The old test lab was initially archived during migration; the archive was later removed during the final cleanup, while the historical explanation remains in this build log.

## Entry 9 — Verifying the OpenAI-compatible path

Before trying to configure OpenCode, a direct Chat Completions request was sent to LiteLLM with model `bedrock-opus` and the gateway master key in the `Authorization: Bearer ...` header.

**Result:** HTTP 200 with `OPENCODE_CHAT_COMPLETIONS_WORKING`.

This showed that the gateway's OpenAI-compatible endpoint itself could complete that model request. The subsequent OpenCode failure was not evidence that the gateway was down.

## Entry 10 — First OpenCode provider configuration: model discovery worked, execution did not

The first generated central config registered a provider ID named `litellm` and made all nine model IDs visible. OpenCode showed entries such as `litellm/free-workhorse`, `litellm/bedrock-opus`, and `litellm/free-glm`.

However, `opencode run --model litellm/free-workhorse ...` produced:

```text
Authentication Error, No api key passed in.
```

This created an important diagnostic distinction:

- `opencode models` listing an entry proved model catalog discovery;
- the `opencode run` authentication error proved that the runtime request did not carry a resolved key.

A later attempt produced `Model unavailable: litellm/free-workhorse` and `Model unavailable: litellm/bedrock-sonnet` under the generated config. The custom provider namespace was not a reliable solution on the observed OpenCode V2 `2.0.25` installation.

**Mistake recorded:** one intermediate correction changed the provider package name to a different package spelling, which was not the working configuration. That was corrected in the subsequently installed sync script. The build should not repeat that speculative package change without testing the exact OpenCode version and schema.

## Entry 11 — Patch pasted into Zsh instead of a Python interpreter

An attempted live patch was delivered as a Python heredoc but only part of the source was pasted/executed in the terminal. Zsh interpreted Python dictionary syntax as shell syntax and printed errors including:

```text
zsh: no matches found: providers[litellm]
zsh: unknown file attribute: \n
zsh: number expected
```

The intended Python transformation did not run correctly. This was a command-entry error, not a LiteLLM model-provider failure.

**Lesson:** code intended for Python must be run through `python3` (or saved as a `.py` file and executed), not pasted line-by-line into Zsh. When this class of error appears, stop and check the target file rather than continuing to paste the rest of the block.

## Entry 12 — First migration installer attempt failed on macOS Bash 3.2

The first attempt to install the gateway-centric package stopped with:

```text
gateway/ai-env.sh: line 70: _ai_env_keys[@]: unbound variable
```

**Cause:** the installer used `set -u` while sourcing `ai-env.sh`. The loader initializes an initially empty Bash array; under the built-in macOS Bash 3.2, expanding the empty array while nounset is enabled can cause this error. The loader itself was not necessarily broken in ordinary Zsh/interactive use; it failed in the installer’s strict-shell context.

**Fix:** a macOS-adjusted installer package was provided. It deliberately avoids nounset (`set -u`) while the current environment loader and helper wrappers are sourced. The original gateway loader was not modified just to mask the installer bug.

**Important safety result:** the failed installer stopped before archiving/removing the live `agent-lab`. It did not restart the gateway.

## Entry 13 — Gateway-centric migration completed after the compatibility fix

The fixed package was extracted and run with:

```bash
bash install.sh --retire-agent-lab
```

It reported:

```text
Updated: $HOME/dev/ai-ops/gateway/opencode.json
Registered 9 model aliases
Default: litellm/free-workhorse
Archiving the old test lab to: .../gateway/backups/agent-lab-retired-20261030-051002.tar.gz
Retired live agent-lab directory; the archive was created during migration and subsequently removed in the 30 October cleanup.
SETUP COMPLETE
Gateway left running; no gateway/LaunchAgent restart was performed.
```

The installer-created backup trees were observed at:

```text
gateway/backups/harness-setup-20261030-050700/
gateway/backups/harness-setup-20261030-051002/
```

It created/installed these files under `gateway/`:

```text
gateway/bin/gw-opencode
gateway/bin/gw-models
gateway/bin/gw-sync-opencode-models
gateway/bin/gw-test-model
gateway/scripts/sync_opencode_models.py
gateway/scripts/test_model.py
gateway/clients/README.md
gateway/opencode.json
```

It did not edit `.env`, `config.yaml`, the virtual environment, the launchd plist, `wrapper_launchd.sh`, `start_gateway.sh`, `gateway.log`, or the KB as part of the installation process. It left the already running gateway process untouched.

## Entry 14 — Replacing the sync helper with the OpenCode V2 catalogue workaround

The migration installer had initially generated `litellm/...` names. Because those still failed, a replacement `scripts/sync_opencode_models.py` was installed from a separate downloaded file. It backed up the prior script:

```text
gateway/scripts/sync_opencode_models.py.backup-20261030-051943
```

The workaround queried the live `/v1/models` API and registered each gateway alias under OpenCode's existing catalog provider using model references such as:

```text
opencode/gw-free-workhorse
opencode/gw-premium
opencode/gw-bedrock-sonnet
opencode/gw-bedrock-opus
opencode/gw-free-glm
```

The `gw-` prefix provides a client-side namespace; the per-model `modelID` still points to the bare LiteLLM alias. The sync script removes stale generated `gw-*` entries while preserving native models in the existing OpenCode provider map.

The regenerated list contained nine gateway aliases:

- `opencode/gw-free-workhorse` → `free-workhorse`
- `opencode/gw-premium` → `premium`
- `opencode/gw-bedrock-sonnet` → `bedrock-sonnet`
- `opencode/gw-bedrock-opus` → `bedrock-opus`
- `opencode/gw-free-openai` → `free-openai`
- `opencode/gw-free-anthropic` → `free-anthropic`
- `opencode/gw-free-kimi` → `free-kimi`
- `opencode/gw-free-glm` → `free-glm`
- `opencode/gw-free-openrouter` → `free-openrouter`

**Result:** OpenCode's model picker displayed the generated `opencode/gw-*` aliases. Model discovery was now working. Authentication still failed at first; the namespace workaround alone was not the final fix.

This implementation was validated on the installed OpenCode V2 `2.0.25` version during this session. Treat it as a compatibility workaround, and re-evaluate after a version upgrade instead of assuming the workaround is permanently necessary.

## Entry 15 — OpenCode authentication resolved after restarting its own service

The gateway environment loader reported the master key was populated (length `42`; the value itself was never printed). `GATEWAY_API_KEY` was unset as the existing harness notes required.

Even after model registration, OpenCode returned:

```text
Authentication Error, No api key passed in.
```

The successful sequence then ran OpenCode's own service status/restart commands after loading the environment:

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

The service printed a local endpoint at `http://127.0.0.1:49374`. The following `opencode run` returned:

```text
> build · gw-free-workhorse
OPENCODE_GATEWAY_OK
```

**Result:** OpenCode-to-LiteLLM authentication and response succeeded. The exact internal reason the prior OpenCode service lacked a resolved key was not independently diagnosed; restarting OpenCode after loading the expected environment is recorded as the operational recovery proven by the test. The model-sync workaround was installed after migration because the first migration-generated `litellm/...` config still did not run successfully.

## Entry 16 — Final OpenCode verification

After the model-sync workaround, `gw-models` listed the nine bare LiteLLM aliases and `gw-opencode models` listed the generated aliases and native OpenCode models.

The first `gw-opencode run` still returned `Authentication Error, No api key passed in`. The service restart described in Entry 15 was followed by a successful `OPENCODE_GATEWAY_OK` response. This ordering matters; it would be inaccurate to say the model-sync script alone fixed auth.

## Entry 17 — GUI/IDE harness Sonnet connection

A separate graphical/IDE harness was configured with a custom provider to use the same LiteLLM gateway. The reported model route was `new-provider/bedrock-sonnet`.

The configuration used:

- gateway address at local port `4000`;
- LiteLLM's master key as the client API key;
- the bare gateway alias `bedrock-sonnet`;
- the Anthropic-compatible Messages API path for that setup.

The user confirmed the model session was running on the Bedrock Sonnet alias and said the setup was working. No raw GUI API response was recorded in the log; this entry preserves the user-observed outcome without fabricating a response body.

**Decision:** keep provider keys in `.env`, not in the harness's provider configuration. The harness stores only the gateway's client key.

## Entry 18 — Documentation gap identified

The original `gateway/README.md` explained the general idea but still contained obsolete operational instructions, including foreground/manual startup advice and a dangerous port-conflict recipe that killed whatever owned port 4000. It also named a specific GUI client, which the public documentation should generalize to “graphical/IDE harness.”

**Decision:** replace the README with a complete walkthrough and maintain a separate chronological build log. Explain the current operational commands, distinguish source configuration from generated client config, list verified and unverified behaviors, and document every known failure/fix from this session.

---

## Problems and fixes index

| Problem | Observed error/symptom | Fix or resolution | Verification |
|---|---|---|---|
| Invalid Bedrock identifier | HTTP 400 invalid model ID | Use the accepted Bedrock inference-profile ID in the configured region | Direct Opus request returned 200 |
| Historical AWS credential lookup error | `NoCredentialsError: Unable to locate credentials` | Correct the configured route/token path; verify current request rather than trusting stale log lines | Later `/v1/messages` and Chat Completions calls returned 200 |
| LaunchAgent existed but was not loaded | `NOT FOUND in launchctl list` | Bootstrap its plist into the user's GUI domain | `launchctl print` showed running service |
| Immediate health check after bootstrap | curl error 7 / HTTP 000 | Wait for LiteLLM startup and poll health | Later health returned 200 |
| Old start script fought launchd | Bootout + `kill -9` when port occupied | Replace with launchd-aware controller that refuses unsafe kills | Healthy controller path reported existing PID healthy |
| Model alias listed but not selectable | `Model unavailable: litellm/...` | Generate `opencode/gw-*` entries under existing catalog provider for tested OpenCode version | New names appeared in model list |
| OpenCode key not passed | `Authentication Error, No api key passed in` | Load gateway env, unset `GATEWAY_API_KEY`, restart OpenCode service | `OPENCODE_GATEWAY_OK` returned |
| Patch interpreted as Zsh | `zsh: no matches found`, `unknown file attribute`, `number expected` | Install/run actual `.py` file through Python; don't paste Python as shell | Later sync helper executed and updated config |
| Empty Bash array with nounset | `_ai_env_keys[@]: unbound variable` | Remove `set -u` from the installer context sourcing current loader | Fixed installer completed successfully |

## Decisions that shaped the current architecture

1. **One gateway remains central.** Do not duplicate upstream secrets across harnesses.
2. **Model aliases are the interface contract.** Harness clients consume the aliases, not provider-specific IDs.
3. **`config.yaml` is the model/routing source of truth.** OpenCode's config is generated from live `/v1/models`.
4. **`launchd` owns the gateway process.** Do not operate a second manual server on the same port as a routine workflow.
5. **OpenCode configuration is central to `gateway/`.** `gw-opencode` uses `OPENCODE_CONFIG`, so the current source repository can be any project directory.
6. **The old task lab is retired.** Its branch-and-commit loop is historical and is not part of the current runtime or operating procedure.
7. **Keep the gateway local-only for the current phase.** Remote network access requires an explicit security design.
8. **Record verified vs. assumed behavior separately.** A catalogue listing is not a successful request; a text response is not a tool-call test; a crash restart is not a full reboot test.

## Open work / next verification checklist

- [ ] Do one natural full Mac restart; after login check `launchctl print`, `/health/liveliness`, and the listener without running `start_gateway.sh` first.
- [ ] Test OpenCode tool calling with a harmless terminal command and no file writes.
- [ ] Test a second model alias end-to-end from OpenCode, such as `opencode/gw-free-glm`, and verify the actual output.
- [ ] Test each needed provider alias separately; record quota/auth/tool-call outcome without storing secrets.
- [ ] Confirm the gateway's `gateway.log` retention/rotation strategy.
- [x] Confirm the staged `.env` file is ignored and absent from the Git index; the 30 October staged-file audit found no matches for the common token patterns it checked. This is not a guarantee against every possible secret format.
- [x] Add `.env.example` with placeholders only; never copy the real `.env` file.
- [ ] Add a portable LaunchAgent plist template or install script if the project must be reproducible on a second Mac; the current plist is outside Git.
- [ ] Make a sanitized example diagnostic log if a public troubleshooting example would help other users.

## Public documentation note

The details above retain command names, filenames, error strings, observed PIDs, and successful response markers because they are part of the engineering history. They intentionally omit API key values. Before publishing, still review runtime logs and commit history; logs and historic commits can expose more than source code.

## Final repository cleanup — 2026-10-30

**Request:** keep one clean project tree after the gateway and both harnesses were working,
remove the old `kb/` directory and timestamped backups, and consolidate documentation.

**Changes planned by the cleanup script:**

1. Installed the detailed gateway walkthrough at `gateway/README.md`.
2. Installed the generic harness guide at `gateway/clients/README.md`.
3. Moved the five knowledge-base topics into `gateway/docs/`; the most detailed build diary
   takes precedence over the earlier shorter build-log file.
4. Added a root `README.md` as the GitHub landing page if one did not already exist.
5. Added root Git ignore rules for `.env`, runtime logs, virtual environments, caches,
   timestamped backups, and backup directories.
6. Removed the root-level downloaded documentation duplicates, the old `kb/` directory,
   `gateway/backups/` (including the retired experimental project archive), and local
   `*.backup-*` / `*.bak.*` files under `gateway/`.

**Safety boundary:** the operation does not alter `gateway/.env`, `config.yaml`, the
LiteLLM virtual environment, the LaunchAgent plist, `wrapper_launchd.sh`, or the running
LiteLLM process. `gateway/gateway.log` remains local for runtime troubleshooting and is
ignored by Git. Recovery backups are intentionally deleted per the user's request.

**Verification already recorded before cleanup:** live `/v1/models` returned nine aliases;
Bedrock Opus returned successful responses through `/v1/messages` and `/v1/chat/completions`;
launchd relaunched LiteLLM after a controlled process termination; OpenCode returned
`OPENCODE_GATEWAY_OK` after restarting its own service with the gateway environment loaded;
the graphical harness was reported working with `bedrock-sonnet`.

**Still not verified:** a complete reboot/login cycle, all nine upstream models, coding-agent
terminal tool calls, log rotation, or public GitHub history hygiene. Do not describe these as
completed until tested.

## Documentation state after the 30 October publication review

The five documentation files were reviewed together because the original architecture map, decision records, and runbook contained stale descriptions of the retired task lab and migration backups. The current documentation set is `gateway/docs/`; historical experiment details remain only where they explain a past decision or failure.

The public-staging audit checked the staged files for several common credential-token patterns and found no matches. `gateway/.env` was confirmed ignored and absent from the Git index. These checks reduce risk but do not prove that every kind of secret is absent. The Git history, local runtime logs, and the remaining README/config comments still require their own review before publication.

Current verified outcomes remain: nine aliases listed by `/v1/models`; Bedrock Opus succeeded through both tested API paths; OpenCode returned `OPENCODE_GATEWAY_OK` through `opencode/gw-free-workhorse`; the graphical harness was reported working through `bedrock-sonnet`; and launchd restarted LiteLLM after a controlled `SIGTERM`. Full reboot/login, tool calling, every provider route, spend-history visibility, and log rotation remain open verification items.
