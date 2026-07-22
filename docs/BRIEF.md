# Launcher hardening brief

## What this is

A set of bash launcher wrappers for AI coding CLIs (claude-code, codex, crush, openclaw, opencode, gemini-cli, aider, deepseek-tui, hermes-agent, nanocoder), packaged inside a Flox environment. Two top-level PATH-shadowing wrappers dispatch subcommands:

- `bin/ollama`  — shadows the real `ollama` binary. Intercepts `ollama launch <tool>` and routes to `bin/launch-<tool>`. Also intercepts `search` / `resolve` / `resolver-info` and forwards to `ollama-model-resolver`. Preprocesses every arg loop, resolving any `--model X?` (trailing `?` = "please resolve") via `ollama-model-resolver` before dispatch. Everything else passes through to the real binary.
- `bin/omlx`   — shadows the real `omlx` binary. Same shape, dispatches `omlx launch <tool>` to `bin/launch-<tool>-omlx`. No resolver support (omlx models are HF repo IDs).

Each `launch-*` script parses `--model`, sources a shared helper (`_ollama-ensure.sh` or `_omlx-ensure.sh`) to guarantee the model is present locally, configures the tool for the local server (usually via an isolated profile/config so the user's default config is never touched), and execs the tool. Some tools need protocol translation via `llamacpp-proxy`; those launchers additionally run `_proxy-ensure.sh` to bring the service up on the right model.

We will be building, packaging, and publishing this as a Flox package. When installed, the scripts will live in `$FLOX_ENV/bin/`. This brief is the pre-publish hardening pass.

## Scope

Do the following, in priority order. Do not refactor beyond what these tasks require. Do not add speculative features. Preserve the existing UX and file layout unless a change is required by a fix.

### 1. Route openclaw / opencode / hermes through their dedicated launchers in `bin/ollama`

**Status: real gap, needs fix.**

`bin/ollama`'s dispatch case handles `gemini | codex | crush | deepseek | aider | nanocoder` but not `openclaw`, `opencode`, or `hermes` — even though `launch-openclaw`, `launch-opencode`, and `launch-hermes` all exist and perform substantive setup:

- `launch-opencode` writes an isolated config to `$FLOX_ENV_CACHE/opencode/opencode.json` and points `XDG_CONFIG_HOME` there so the user's `~/.config/opencode` is never touched.
- `launch-openclaw` patches an isolated `--profile ollama` config via `openclaw config patch --stdin` and execs `openclaw --profile ollama chat` so the user's default profile is never touched.
- `launch-hermes` sets `OPENAI_BASE_URL` / `OPENAI_API_KEY=ollama` and execs `hermes-agent` directly, bypassing `ollama launch` entirely.

All three also call `ollama_ensure_model` (pull-if-missing via `/api/pull`) — an explicit guarantee independent of whatever version-specific behavior real ollama's native `launch` has.

**Note on framing**: the `?`-model resolver already works for these tools today, because `bin/ollama`'s preprocessing loop resolves `?` args for every tool including the `*)` fallthrough. So the missing piece is **not** resolver wiring — it is the isolated-config and explicit ensure-model behavior that only the dedicated launchers provide. Currently `ollama launch openclaw|opencode|hermes` runs real ollama's native launch, which uses the user's default profile/config.

**Action**: add the missing cases to `bin/ollama`. Match the alias style used in `bin/omlx` where appropriate (`hermes | hermes-agent`, etc.). Confirm each of the three dedicated launchers is functionally what should run.

### 2. Fix silent exit on `ollama launch` with no tool

**Status: reproducible bug.**

```
$ bash bin/ollama launch
$ echo $?
1
```

No message. Cause: after the launch-intercept guard, `bin/ollama` does `TOOL="${2:-}"; shift 2` unconditionally. When `$#` is 1, `shift 2` returns non-zero and `set -e` aborts. Print a clear usage error listing the dispatched tools and exit 2. `bin/omlx` does not have this bug (its `shift 2` is inside matched case branches; the bare-`launch` path hits `*)` and falls through cleanly to real omlx, which prints its own usage).

### 3. Fix confusing double error when the real backend binary is missing

**Status: real UX bug, present in both wrappers.**

Both wrappers do `exec "$(_real_ollama)" "$@"` (and `_real_omlx` equivalent). If `_real_*` fails to find the binary, it prints its own error and returns 1 — but `set -e` does not propagate out of `$(…)`, so execution continues and `exec ""` fires, producing:

```
Error: cannot find ollama binary
bash: line N: exec: : not found
```

Capture the resolved path into a variable, check it, then exec:

```bash
real="$(_real_ollama)" || exit $?
exec "$real" "$@"
```

Apply the same pattern to every `exec "$(_real_*)"` in both wrappers.

### 4. General hardening — apply where they add value, don't invent problems

Across all scripts in `bin/`, review for the following and fix where genuinely warranted. Do not add checks that guard against impossible states.

- **Idempotency**: launchers should be safe to re-invoke back-to-back with the same or different models. `_proxy-ensure.sh` already uses a state file and restarts only when model changes or health fails — verify that logic holds for concurrent invocations. If two `launch-*` invocations race on the same proxy service, one may see a healthy proxy configured for the wrong model. Consider whether this needs a lock or is acceptable.
- **Correctness of the `_resolve_next` state machine in `bin/ollama`**: it currently consumes the next arg unconditionally after seeing `--model` or `-m`. If a user writes `--model --other-flag foo` (pathological but possible), the literal `--other-flag` gets fed to the resolver. Decide whether to guard against this or leave it.
- **Robustness of `SCRIPT_DIR` resolution**: currently `SCRIPT_DIR="${BASH_SOURCE[0]%/*}"`, which can be relative (e.g., `.`) when the script is invoked as `./bin/ollama`. Nothing `cd`s between init and exec today, so this works — but it's fragile against future edits. Consider `SCRIPT_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)"` once at the top. This also lets `_real_*` skip its per-PATH-entry `cd`/`pwd` and just do string compares, a marginal perf win.
- **`_real_*` symlink self-detection**: uses `cd && pwd` (logical) on both sides. Not a loop hazard in practice (at worst one bounce of exec, terminating). `pwd -P` on both sides would be tidier but is not required.
- **Empty PATH components**: currently harmless (probe becomes `/ollama`, not `./ollama`). Filter or leave alone — do not make this a security narrative.
- **Consistency between the two wrappers**: `bin/omlx` has `claude|claude-code` and `hermes|hermes-agent` aliases; `bin/ollama` has none. Add matching aliases where the underlying launcher exists.
- **Timeouts and grep patterns in `_*-ensure.sh`**: already have `--connect-timeout` / `--max-time` and exact-match grep with trailing comma. Preserve these invariants — do not weaken them during refactoring.
- **JSON interpolation**: launchers escape `$MODEL` (`\` → `\\`, `"` → `\"`) before interpolating into JSON bodies. Preserve. Where `jq -n --arg` can replace hand-escaping (as `launch-opencode` does), prefer it.
- **Trap discipline**: any launcher that owns a background process or temp file must trap `EXIT INT TERM HUP` (all four) and must NOT `exec` the tool — the shell has to survive to run the trap. `_omlx-ensure.sh` sets an intermediate trap for its cookie file with a comment about the calling script overwriting it; verify no launcher accidentally clobbers a still-needed trap.
- **Bash 3.2 compat**: macOS ships bash 3.2. Empty-array expansion must use `${arr[@]+"${arr[@]}"}`. Do not introduce bash 4+ features (`declare -A`, `mapfile`, `${var,,}`, etc.).
- **Performance**: these are one-shot dispatchers, so wall-time matters more than throughput. Avoid adding subprocess spawns to hot paths (the arg-resolve loop, the PATH walk). The resolver call is the expensive step and is already gated by the `?` suffix — do not call it speculatively.

### 5. Do NOT do

- Do not add a `--help` layer to the wrappers. `--help` passthrough to the real binary is intentional.
- Do not merge `_real_ollama` and `_real_omlx` into a shared helper unless it demonstrably simplifies both. 12 lines of duplication is fine.
- Do not add logging/telemetry. These are local dev tools.
- Do not add a lockfile / mutex unless #4's proxy-race analysis proves it's needed.
- Do not change the wrapper's "install-into-`$FLOX_ENV/bin`" layout assumption.

## Test plan

For each fix, provide a bash one-liner that reproduces the bug before the change and confirms correct behavior after. Example for #2:

```
$ bash bin/ollama launch
# before: silent exit 1
# after:  "Usage: ollama launch <tool> ..." on stderr, exit 2
```

## Deliverable

Modified files under `bin/`, with a short changelog listing each fix and the reasoning. If any of the "general hardening" items in §4 turn out to be non-issues on closer inspection, say so explicitly rather than making a no-op change.
