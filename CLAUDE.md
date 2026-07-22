# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

The **build environment** for the `agentic-launchers` Flox package. Ships:

- A `bin/launch` dispatcher and a set of `launch-<tool>[-omlx]` scripts that wrap ~10 AI coding CLIs (aider, claude, codex, crush, deepseek, gemini, hermes, nanocoder, openclaw, opencode) and point them at a local LLM server.
- A Go-based `launcher-lock-helper` (`native/launcher-lock-helper/`) that arbitrates concurrent launcher runs via `flock(2)`.

One top-level Flox package built via a Nix expression in `.flox/pkgs/`:
- `agentic-launchers` — the shell layer plus the bundled `_launcher-lock-helper` binary (built as a scoped intermediate from `launcher-lock-helper.nix` and copied into the same `$out/bin`)

The **runtime environment** — where these packages are consumed — lives at `~/dev/agentic-playground/` (a `flox init` env that pins both packages via `store-path` for local testing before publish). This repo is not intended to be activated for launcher use; only for launcher development.

## User-facing entry point

One command:

```
launch <tool> [--model <model>] [--backend ollama|omlx] [tool args...]
```

Backend is auto-detected (omlx on macOS Apple Silicon, ollama elsewhere), overridable via `--backend` or `$AGENTIC_BACKEND`. Real `ollama` and `omlx` binaries are **not shadowed** — `ollama serve` etc. remain the user's `ollama serve`.

## Working in this env

`.flox/` exists at the repo root, so **every shell command must run through Flox**, not raw Bash. Use `mcp__flox__run_command` with the absolute repo path as `working_dir`.

The env is registered on FloxHub as `flox/agentic-launchers`. `flox build` refuses to run from a FloxHub-linked env — for iteration, use a `flox pull --copy` scratch dir (see `/tmp/agentic-scratch` in most sessions).

Common checks:
- `bash tests/test-launchers.sh` (also under `BASH_COMPAT=3.2`) — 55 checks
- `bash tests/test-proxy-record-auth.sh` — 7 checks
- `bash tests/test-lock-crash.sh` — 5 checks
- Total: **67 checks**. Set `LAUNCHER_LOCK_HELPER=/path/to/_launcher-lock-helper` if the helper isn't on `PATH` yet.

## Architecture

`bin/launch` is a small (~200 line) dispatcher:

1. Parses args (`--backend`, `--model`, `--list-tools`, `--help`, and passthrough)
2. Resolves the backend (explicit flag > `$AGENTIC_BACKEND` > platform default)
3. Validates that the tool exists for the chosen backend
4. For ollama backend, rewrites `--model X?` via `ollama-model-resolver`
5. `exec`s `bin/launch-<tool>` (ollama) or `bin/launch-<tool>-omlx` (omlx) with the resolved args

Each `launch-*` script follows the same shape:
1. Parses `--model` out of argv, keeps the rest as passthrough
2. Sources a shared ensure-helper to guarantee the model is present locally
3. Configures the tool via env vars or by patching an isolated profile dir (never touches the user's default config)
4. For tools that need protocol translation, runs `proxy_ensure_model` to bring `llamacpp-proxy-*` up on the right model
5. `exec`s the tool — **except** when the launcher owns a background proxy it must clean up. In that case, runs the tool as a foreground child with `trap ... EXIT INT TERM HUP`

Shared helpers in `bin/` (sourced, never executed):
- `_ollama-ensure.sh` — `ollama_normalize_base_url`, `ollama_ensure_model` (checks `/api/tags`, pulls via `/api/pull` if missing)
- `_omlx-ensure.sh` — waits for omlx readiness, resolves the API key (macOS keychain → `~/.omlx/settings.json` → `$FLOX_ENV_CACHE/omlx.api-key`), resolves a HuggingFace token, drives omlx's admin download API for missing models. Exports `OMLX_API_KEY` and `OMLX_MODEL_ID`
- `_proxy-ensure.sh` — schema-v2 identity-bound records; restarts `llamacpp-proxy-*` when the request identity differs from the committed record or the listener is unhealthy
- `_launcher-common.sh` — SHA-256 profile keys, atomic file writes via native `rename(2)`, kernel-lock acquire/release, timeout-bounded process-tree termination
- `_launcher_lock_helper_path` — honors `$LAUNCHER_LOCK_HELPER` env var (test/dev), else `command -v _launcher-lock-helper` on PATH

Protocol mapping (why some tools need llamacpp-proxy and others don't):
- `claude` speaks Anthropic Messages — both omlx and ollama serve compatible endpoints natively
- `codex`, `opencode`, `hermes`, `aider`, `deepseek`, `nanocoder`, `crush`, `openclaw` — OpenAI-compat, talk directly to ollama's `/v1` or to omlx
- `gemini` speaks the Gemini API — always needs `llamacpp-proxy` to translate Gemini ↔ OpenAI ↔ backend

## Nix packaging notes

`.flox/pkgs/agentic-launchers.nix` — `stdenv.mkDerivation`, `src = lib.fileset.toSource { root = ../..; fileset = unions [ ../../bin ../../etc ]; }`, `dontPatchShebangs = true` (runtime PATH resolves `bash`/`curl`/`jq`). Installs `bin/*` and `etc/agentic-bootstrap.sh`. Also builds `launcher-lock-helper.nix` via `callPackage` and copies its `_launcher-lock-helper` binary into `$out/bin/`, so consumers install one package and get both binaries. Chmod 755 on `launch`, `launch-*`, and `_launcher-lock-helper`.

`.flox/pkgs/launcher-lock-helper.nix` — `buildGoModule`, `vendorHash = null` (stdlib only), renames output binary to `_launcher-lock-helper` in `postInstall`. Kept as a scoped intermediate; only `agentic-launchers` is exposed as a consumer-facing build.

`etc/agentic-bootstrap.sh` — sourced by the runtime env's `[hook] on-activate`. Sets `OLLAMA_*` / `OMLX_*` / `LLAMACPP_PROXY_*` env vars with defaults. `OLLAMA_CONTEXT_LENGTH` defaults to `32768` (fits mainstream coding models). The build env's own manifest doesn't source this file — it exists only for consumers.

## Conventions to preserve when editing launchers

These were established during red-team review — deviating re-opens fixed bugs:

- **Escape `$MODEL` before JSON interpolation**: `MODEL_JSON="${MODEL//\\/\\\\}"; MODEL_JSON="${MODEL_JSON//\"/\\\"}"`. Prefer `jq -n --arg` where structure allows.
- **Exact-match model checks**: `jq -e 'select(.id == $m or .id == $s)'`, or grep for `"name":"model:tag",` with the trailing comma. Substring matches produce false positives.
- **curl timeouts on every call**: `--connect-timeout` + `--max-time`. No unbounded network calls.
- **Trap `EXIT INT TERM HUP`** (all four) whenever a launcher owns a background process or temp file. Do not `exec` in that case — the shell must survive to run the trap.
- **Bash 3.2 compatible**: macOS ships 3.2. Empty-array expansion via `${arr[@]+"${arr[@]}"}`. No `declare -A`, no `mapfile`, no `${var,,}`.
- **Isolated tool profiles**: never mutate the user's default config. Use `--profile ollama` (openclaw), `$FLOX_ENV_CACHE`-scoped configs via `XDG_CONFIG_HOME` or `-D` flags, etc.
- **Log proxy stderr to `$FLOX_ENV_CACHE/*.log`**, not `/dev/null`.
- **SCRIPT_DIR resolves symlinks fully.** `bin/launch` uses a manual readlink loop, not `readlink -f` (macOS built-in readlink lacks `-f`).

## Reference documents

- `docs/BRIEF.md` — hardening pass scope handed to the review model
- `docs/HARDENING_CHANGELOG.md` — what that pass added
- `docs/BRIEF-MACOS.md` — original macOS/omlx integration design
- `docs/FLOX.md` — general Flox authoring guide
