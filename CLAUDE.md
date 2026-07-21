# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Flox environment that bundles ~9 CLI coding agents (claude-code, codex, crush, openclaw, opencode, gemini-cli, aider, deepseek-tui, hermes-agent, nanocoder) and points them all at a local LLM server. The value-add is `bin/` — a set of bash launcher wrappers that give every tool the same UX regardless of backend:

```
ollama launch <tool> --model <model>   # Linux (ollama backend)
omlx   launch <tool> --model <model>   # macOS (omlx / MLX backend)
```

There is no application source code — this project is entirely shell wrappers + Flox manifest.

## Working in the environment

`.flox/` exists at the repo root, so **every shell command must run through Flox**, not raw Bash. Use the `mcp__flox__run_command` tool with the absolute repo path as `working_dir`. Do not `cd` into the repo and call bash directly — you will get the wrong versions of `jq`, `gum`, `bash`, the AI CLIs, etc.

There is no build, no test suite, no linter. "Development" means editing bash scripts in `bin/` or the Flox manifest, then invoking a launcher to verify behavior.

Common manual checks:
- `flox activate -s` — activate env and start services (llamacpp-proxy-ollama, llamacpp-proxy-omlx)
- `flox services status` / `flox services restart <name>` — the launchers restart proxy services when a model changes; see `bin/_proxy-ensure.sh`
- `ollama launch <tool> --model <model>` — smoke test a Linux launcher end-to-end
- Proxy logs land in `$FLOX_ENV_CACHE/llamacpp-proxy-*.log`

## Architecture

Two entry-point wrappers shadow the real backend binaries via `PATH`:

- `bin/ollama` — intercepts `ollama launch <tool>` and dispatches to `bin/launch-<tool>`. Everything else passes through to the real `ollama` binary (resolved by walking `$PATH` and skipping this wrapper's own dir). It also intercepts `search` / `resolve` / `resolver-info` and forwards to `ollama-model-resolver`, and rewrites any `--model <name>?` argument by calling the resolver (the trailing `?` = "please resolve").
- `bin/omlx` — same pattern for the macOS omlx backend; dispatches to `bin/launch-<tool>-omlx`.

Each `launch-*` script follows the same shape:
1. Parse `--model <m>` out of argv, keep the rest as passthrough args.
2. `source` a shared ensure-helper to guarantee the model is present locally.
3. Configure the tool (via env vars, or by patching an isolated profile dir like `~/.openclaw-ollama/` or a generated crush config in `$FLOX_ENV_CACHE`) so it points at the local server.
4. For tools that need protocol translation, `proxy_ensure_model` restarts `llamacpp-proxy-*` with the requested model. Everything else talks directly to the backend.
5. `exec` the tool — **except** when a launcher owns a background proxy it must clean up. In that case, run the tool as a foreground child with `trap ... EXIT INT TERM HUP` (see the "no exec for proxy-dependent tools" note in `BRIEF-MACOS.md`).

Shared helpers in `bin/` (all sourced, never executed):
- `_ollama-ensure.sh` — `ollama_normalize_host_port`, `ollama_ensure_model` (checks `/api/tags`, pulls via `/api/pull` if missing).
- `_omlx-ensure.sh` — waits for omlx readiness, resolves the omlx API key (macOS keychain → `~/.omlx/settings.json` → `$FLOX_ENV_CACHE/omlx.api-key`), resolves a HuggingFace token, and drives omlx's admin download API to fetch missing models. Exports `OMLX_API_KEY`.
- `_proxy-ensure.sh` — writes desired model to a state file under `$FLOX_ENV_CACHE`, restarts the `llamacpp-proxy-*` service if the model changed or health check fails, waits for it to come back.

Protocol mapping (why some tools need llamacpp-proxy and others don't):
- claude-code speaks Anthropic Messages — omlx serves it natively; on ollama, no direct path (use `launch-claude-omlx` on macOS).
- codex, opencode, hermes-agent, aider, deepseek-tui, nanocoder, crush, openclaw — OpenAI-compat, talk directly to ollama's `/v1` or to omlx.
- gemini-cli speaks the Gemini API — always needs `llamacpp-proxy` to translate Gemini ↔ OpenAI ↔ backend.

## Flox manifest notes

`.flox/env/manifest.toml` pins every AI CLI to its own `pkg-group` (so upgrades are isolated) and includes remote envs `flox-labs/omlx` and `flox-labs/ollama`. The `[hook]` block sets the default host/port env vars every launcher reads (`OLLAMA_HOST/PORT`, `OMLX_HOST/PORT`, `LLAMACPP_PROXY_*_LISTEN`, `OPENAI_API_BASE`, `OPENAI_API_KEY=ollama`). `[profile] common` prepends `$FLOX_ENV_PROJECT/bin` to PATH so the wrappers shadow the real binaries.

`llamacpp-proxy` is gated to `x86_64-linux`, `aarch64-linux`, `aarch64-darwin` — **not** Intel Mac. `flox-mcp-server` is `x86_64-linux` + `aarch64-darwin` only. `ollama-model-resolver` is pinned to a specific `store-path` and `x86_64-linux` only.

## Conventions to preserve when editing launchers

These were established during red-team review — deviating from them re-opens fixed bugs:

- **Escape `$MODEL` before JSON interpolation**: `MODEL_JSON="${MODEL//\\/\\\\}"; MODEL_JSON="${MODEL_JSON//\"/\\\"}"`. Every launcher that writes JSON does this.
- **Exact-match model checks**: grep for `"name":"model:tag",` with the trailing comma, or use `jq -e 'select(.id == $m or .id == $s)'`. Substring matches produce false positives.
- **curl timeouts on every call**: `--connect-timeout` + `--max-time`. No unbounded network calls.
- **Trap `EXIT INT TERM HUP`** (all four) whenever a launcher owns a background process or temp file. Do not `exec` in that case — the shell must survive to run the trap.
- **Bash 3.2 compatible**: macOS ships 3.2. Expand possibly-empty arrays as `${arr[@]+"${arr[@]}"}`.
- **Isolated tool profiles**: never mutate the user's default config for a tool. Use `--profile ollama` (openclaw), a generated config in `$FLOX_ENV_CACHE` with `-D` (crush), etc. `XDG_CONFIG_HOME` is not honored on macOS — don't rely on it.
- **Log proxy stderr to `$FLOX_ENV_CACHE/*.log`**, not `/dev/null`.

## Reference documents in the repo

- `BRIEF-MACOS.md` — original design brief and red-team history. Read this before making non-trivial changes to the launcher architecture.
- `FLOX.md` — Flox environment authoring guide.
