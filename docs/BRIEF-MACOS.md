# macOS Integration Brief

## What exists

This repo (`agentic-playground`) is a Flox environment containing 9 CLI coding tools that all talk to a local LLM server. We built a wrapper system so every tool launches with the same UX:

```
# Linux (ollama backend)
ollama launch <tool> --model <model>

# macOS (omlx backend) — TO BE BUILT
omlx launch <tool> --model <model>
```

### Tools and their backend requirements

| Tool | Ollama launch support | Protocol | Needs proxy? |
|------|----------------------|----------|-------------|
| claude-code | native | Anthropic Messages | no |
| codex | native | OpenAI Responses | no |
| opencode | native | OpenAI Chat | no |
| hermes-agent | native | OpenAI Chat | no |
| crush (openclaw) | native as `openclaw`; **wrapper** as `crush` | OpenAI-compat | **yes** (llamacpp-proxy) |
| gemini-cli | **wrapper** | Gemini native | **yes** (llamacpp-proxy) |
| deepseek-tui | **wrapper** | ollama native | no |
| aider-chat | **wrapper** | ollama native | no |

### File inventory

```
bin/
  ollama              # PATH-shadowing wrapper; dispatches `ollama launch <tool>`
                      # to launch-* scripts for unsupported tools, passes everything
                      # else to the real ollama binary
  _ollama-ensure.sh   # Sourced helper; checks if model exists locally via
                      # GET /api/tags, pulls if missing via POST /api/pull
  launch-gemini       # Starts llamacpp-proxy (Gemini API translation), launches gemini-cli
  launch-crush        # Starts llamacpp-proxy (OpenAI-compat), generates isolated
                      # crush.json in $FLOX_ENV_CACHE, launches crush
  launch-deepseek     # Native --provider ollama, no proxy
  launch-aider        # Native ollama_chat/ prefix, no proxy

.flox/env/manifest.toml  # Flox environment definition
FLOX.md                   # Flox environment creation guide
```

### Architecture

```
User runs: ollama launch gemini --model qwen2.5-coder

bin/ollama (wrapper)
  ├── intercepts "launch gemini" → exec bin/launch-gemini --model qwen2.5-coder
  │   (this exec is fine — the wrapper has no background processes to clean up;
  │    the launch-* scripts themselves do NOT exec, see step 6 below)
  └── passes all other commands to real ollama

bin/launch-gemini
  1. source _ollama-ensure.sh
  2. ollama_ensure_model (check /api/tags, pull if missing)
  3. start llamacpp-proxy in background (Gemini API ←→ OpenAI Chat ←→ ollama)
  4. trap cleanup EXIT INT TERM HUP
  5. set GOOGLE_GEMINI_BASE_URL to proxy's gemini listener
  6. run gemini-cli as foreground child (NOT exec — shell stays alive for cleanup)
  7. on exit: trap fires, kills proxy
```

### Key design decisions already made

- **No `exec` for proxy-dependent tools** — the tool runs as a foreground child so the shell stays alive and the EXIT trap cleans up the proxy. This was the #1 bug found during red teaming.
- **Crush config isolation** — crush.json generated in `$FLOX_ENV_CACHE/crush/` via `-D` flag, not `XDG_CONFIG_HOME` (XDG doesn't work on macOS).
- **JSON escaping** — `$MODEL` is escaped (`\` → `\\`, `"` → `\"`) before interpolation into JSON bodies.
- **Proxy stderr logged** — goes to `$FLOX_ENV_CACHE/llamacpp-proxy-{tool}.log`, not `/dev/null`.
- **curl timeouts** — `--connect-timeout 5`, `--max-time 10` on tags, `--max-time 600` on pull.
- **grep exact match** — trailing comma `"name":"model:tag",` prevents substring false-positives.
- **Bash 3.2 compat** — empty arrays use `${arr[@]+"${arr[@]}"}` pattern.

### Manifest hook (sets defaults)

```toml
[hook]
on-activate = '''
  export OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1}"
  export OLLAMA_PORT="${OLLAMA_PORT:-11434}"
  export OPENAI_API_BASE="${OPENAI_API_BASE:-http://127.0.0.1:11434/v1}"
  export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
'''

[profile]
common = '''
  export PATH="$FLOX_ENV_PROJECT/bin:$PATH"
'''
```

## What you need to do

### 1. Verify cross-platform correctness

- **llamacpp-proxy availability**: The manifest has `llamacpp-proxy.systems = ["aarch64-darwin", "aarch64-linux", "x86_64-linux"]`. It's available on Apple Silicon Macs but NOT Intel Macs (`x86_64-darwin` is missing). Verify this. If you're on Intel Mac, gemini and crush wrappers won't work without a workaround.
- **bash version**: macOS ships bash 3.2. The Flox env may provide a newer bash. Check which bash `#!/usr/bin/env bash` resolves to. The `${arr[@]+"${arr[@]}"}` pattern was added for 3.2 compat — verify it works.
- **`seq` command**: Used in health check loops (`seq 1 30`). Available on macOS via coreutils but might not be in base system. Test it.
- **`curl` behavior**: macOS curl may have different defaults. The `--connect-timeout` and `--max-time` flags should work everywhere.
- **`ss` vs `lsof`**: Not used in scripts but useful for debugging. macOS doesn't have `ss`, use `lsof -i :PORT` instead.

### 2. Add omlx as an alternative backend

`omlx` is a macOS-native MLX-based LLM runtime. On macOS, the UX should be:

```
omlx launch <tool> --model <model>
```

This mirrors the Linux UX (`ollama launch <tool> --model <model>`) but uses omlx as both the command and the backend.

The current wrappers assume ollama. You need to create a parallel `bin/omlx` wrapper that:
- Shadows the real `omlx` binary the same way `bin/ollama` shadows the real `ollama`
- Intercepts `omlx launch <tool>` for unsupported tools
- Dispatches to launch-* scripts configured for the omlx backend

**Desired behavior**: `omlx launch <tool> --model <model>` should do exactly what `ollama launch <tool> --model <model>` does on Linux — ensure the model is available locally, then launch the tool pointed at the local server. The user should not have to think about backend differences.

**Key difference from ollama**: omlx cannot pull models on its own. It relies on the Hugging Face CLI (`huggingface-cli`, which omlx ships) for model downloads. It also requires a local OAuth token at startup and a Hugging Face token if one isn't already configured. The exact mechanics of these are for you to determine on the macOS machine.

**Your job on macOS**:
1. Research omlx: run `omlx --help`, `omlx launch --help`, check its API endpoints, figure out the auth flow, understand how it discovers locally-available models
2. Determine what `_omlx-ensure.sh` needs to do — it must be functionally equivalent to `_ollama-ensure.sh` (check if model exists locally, download if not) but using omlx's model management (likely `huggingface-cli download` or similar)
3. Determine which tools `omlx launch` supports natively vs which need wrappers
4. Build `bin/omlx` and any omlx-specific launch-* variants or env var overrides needed
5. Handle the auth bootstrapping (HF token check, OAuth token) — fail fast with a clear message if not configured

### 3. Suggested starting point

The Linux side uses `bin/ollama` → `_ollama-ensure.sh` → `launch-*` scripts. The macOS side likely needs a parallel `bin/omlx` → `_omlx-ensure.sh` → possibly shared or forked launch-* scripts. Whether the launch scripts can be shared (parameterized by backend) or need omlx-specific variants is for you to decide once you understand omlx's API and tool integration surface. Don't over-abstract — if forking a script is cleaner than parameterizing it, fork it.

### 4. Red team findings — already fixed

These were found across 5 independent red team rounds and are already addressed in the current code:

1. ~~Orphaned proxy~~ → removed `exec`, tool runs as foreground child
2. ~~JSON injection~~ → model name escaped for JSON
3. ~~grep substring match~~ → trailing comma for exact match
4. ~~No curl timeouts~~ → added connect-timeout and max-time
5. ~~SIGHUP not trapped~~ → added HUP to trap
6. ~~stderr suppression~~ → proxy stderr goes to log file
7. ~~Port collisions~~ → mitigated by proper cleanup; errors reference log

### 5. Red team findings — not fixed (low practical risk in local dev)

- SSRF via `OLLAMA_HOST`/`OLLAMA_PORT` env vars (user controls their own env)
- Symlink resolution in `bin/ollama` (`pwd` vs `pwd -P`)
- `set -e` disabled inside `ollama_ensure_model` due to `||` context
- Symlink following on `crush.json` write
- Empty PATH component CWD hijack in `_real_ollama()`

These were deprioritized as low practical risk for a local dev tool. Revisit if the threat model changes.

## How to get started

```bash
# Read this file
# Read FLOX.md for Flox conventions
# Read each script in bin/ — they're short
# Check: which bash, llamacpp-proxy --help, omlx --help
# Test: ollama launch gemini --model <available-model>
# Then extend for omlx
```
