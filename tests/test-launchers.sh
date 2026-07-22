#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
TMP="$(mktemp -d -t launcher-tests.XXXXXX)"
if [[ "${KEEP_TEST_TMP:-0}" == "1" ]]; then
  echo "test temp directory: $TMP" >&2
else
  trap 'rm -rf "$TMP"' EXIT INT TERM HUP
fi

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf 'ok %d - %s\n' "$PASS" "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'not ok - %s\n' "$1" >&2
  return 1
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" == "$expected" ]] || {
    printf 'expected: <%s>\nactual:   <%s>\n' "$expected" "$actual" >&2
    fail "$label"
  }
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || {
    printf 'missing <%s> in:\n%s\n' "$needle" "$haystack" >&2
    fail "$label"
  }
}

assert_file_eq() {
  local expected="$1" file="$2" label="$3" actual=""
  actual="$(cat "$file")"
  assert_eq "$expected" "$actual" "$label"
}

assert_not_live() {
  local pid="$1" label="$2" stat=""
  stat="$(ps -p "$pid" -o stat= 2>/dev/null | tr -d ' ' || true)"
  [[ -z "$stat" || "$stat" == Z* ]] || fail "$label"
}

wait_for_process_file() {
  local file="$1" pid="$2" label="$3" attempts="${4:-500}" stat="" status=0
  while [[ ! -e "$file" && "$attempts" -gt 0 ]]; do
    stat="$(ps -p "$pid" -o stat= 2>/dev/null | tr -d ' ' || true)"
    if [[ -z "$stat" || "$stat" == Z* ]]; then
      set +e
      wait "$pid" 2>/dev/null
      status=$?
      set -e
      printf 'producer exited with status %s before creating %s\n' "$status" "$file" >&2
      fail "$label"
      return 1
    fi
    sleep 0.02
    attempts=$((attempts - 1))
  done
  if [[ ! -e "$file" ]]; then
    printf 'timed out waiting for %s from process %s\n' "$file" "$pid" >&2
    kill -TERM "$pid" 2>/dev/null || true
    fail "$label"
    return 1
  fi
}

make_fake_command() {
  local path="$1"
  shift
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf '%s\n' "$@"
  } > "$path"
  chmod 755 "$path"
}

_locate_lock_helper() {
  local h=""
  if [[ -n "${LAUNCHER_LOCK_HELPER:-}" && -x "$LAUNCHER_LOCK_HELPER" ]]; then
    printf '%s' "$LAUNCHER_LOCK_HELPER"; return 0
  fi
  for h in \
    "$ROOT/result-launcher-lock-helper/bin/_launcher-lock-helper" \
    "$ROOT/../agentic-scratch/result-launcher-lock-helper/bin/_launcher-lock-helper"
  do
    if [[ -x "$h" ]]; then printf '%s' "$h"; return 0; fi
  done
  h="$(command -v _launcher-lock-helper 2>/dev/null || true)"
  if [[ -n "$h" && -x "$h" ]]; then printf '%s' "$h"; return 0; fi
  return 1
}

copy_lock_runtime() {
  local destination="$1" src=""
  src="$(_locate_lock_helper)" || {
    echo "Error: no _launcher-lock-helper found (set LAUNCHER_LOCK_HELPER, build via 'flox build launcher-lock-helper', or install)" >&2
    exit 1
  }
  cp "$src" "$destination/_launcher-lock-helper"
  chmod 755 "$destination/_launcher-lock-helper"
}

WRAP="$TMP/wrap"
RESOLVER="$TMP/resolver"
NO_RESOLVER="$TMP/no-resolver"
mkdir -p "$WRAP" "$RESOLVER" "$NO_RESOLVER"
cp "$ROOT/bin/launch" "$WRAP/launch"
chmod 755 "$WRAP/launch"

# Fake launch-<tool>[-omlx] for every advertised tool. Each prints
# "launcher:<name>" followed by "<arg>" per received arg, so tests can
# assert both which launcher was dispatched and what was forwarded.
for tool in aider codex crush deepseek gemini hermes nanocoder openclaw opencode; do
  make_fake_command "$WRAP/launch-$tool" \
    'printf "launcher:%s" "${0##*/}"' \
    'for arg in "$@"; do printf " <%s>" "$arg"; done' \
    'printf "\\n"'
done
for tool in aider claude codex crush deepseek gemini hermes nanocoder openclaw opencode; do
  make_fake_command "$WRAP/launch-$tool-omlx" \
    'printf "launcher:%s" "${0##*/}"' \
    'for arg in "$@"; do printf " <%s>" "$arg"; done' \
    'printf "\\n"'
done

# Resolver fake for the '?' resolution tests. Trims the trailing '?' and
# appends -resolved so an input like alpha? becomes alpha-resolved.
make_fake_command "$RESOLVER/ollama-model-resolver" \
  '[[ "${1:-}" == "resolve" ]] || exit 3' \
  'value="${2:-}"' \
  'printf "%s-resolved" "${value%?}"'

# Convenience: default test PATH (with resolver on it).
LAUNCH_PATH="$WRAP:$RESOLVER:/usr/bin:/bin"
# PATH without the resolver, for "resolver-not-on-PATH" tests.
LAUNCH_PATH_NORES="$WRAP:$NO_RESOLVER:/usr/bin:/bin"

# 1. Bare `launch` is a usage error, not a silent shift abort.
set +e
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" 2>&1)"
status=$?
set -e
assert_eq "2" "$status" "bare launch exits 2"
assert_contains "$out" "Usage: launch <tool>" "bare launch prints usage to stderr"
pass "bare launch is a usage error"

# 2. --help and --list-tools succeed and produce expected content.
set +e
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --help)"
status=$?
set -e
assert_eq "0" "$status" "--help exits 0"
assert_contains "$out" "Usage: launch <tool>" "--help prints usage"
assert_contains "$out" "omlx only" "--help mentions omlx-only tools"
set +e
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --list-tools)"
status=$?
set -e
assert_eq "0" "$status" "--list-tools exits 0"
expected_list=$'aider\nclaude\ncodex\ncrush\ndeepseek\ngemini\nhermes\nnanocoder\nopenclaw\nopencode'
assert_eq "$expected_list" "$out" "--list-tools prints 10 tools alphabetically"
pass "help and list-tools work"

# 3. Unknown tool and leading-dash pseudo-tool are rejected with usage help.
set +e
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" bogus 2>&1)"
status=$?
set -e
assert_eq "2" "$status" "unknown tool exits 2"
assert_contains "$out" "unknown tool 'bogus'" "unknown tool diagnosed"
assert_contains "$out" "aider" "unknown tool error lists tools"
set +e
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" -bogus 2>&1)"
status=$?
set -e
assert_eq "2" "$status" "leading-dash tool exits 2"
assert_contains "$out" "unknown option or missing tool" "leading-dash tool diagnosed"
pass "unknown and leading-dash tool names are rejected"

# 4. Linux default backend dispatches every ollama-side tool.
for tool in aider codex crush deepseek gemini hermes nanocoder openclaw opencode; do
  out="$(AGENTIC_BACKEND="" PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend ollama "$tool" --model alpha)"
  assert_eq "launcher:launch-${tool} <--model> <alpha>" "$out" "dispatch --backend ollama $tool"
done
pass "ollama backend dispatches every ollama-side tool"

# 5. Explicit --backend, --backend=, $AGENTIC_BACKEND, and flag-beats-env
# all route to the omlx launchers.
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend omlx gemini --model alpha)"
assert_eq "launcher:launch-gemini-omlx <--model> <alpha>" "$out" "--backend omlx"
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend=omlx gemini --model alpha)"
assert_eq "launcher:launch-gemini-omlx <--model> <alpha>" "$out" "--backend=omlx"
out="$(AGENTIC_BACKEND=omlx PATH="$LAUNCH_PATH" bash "$WRAP/launch" gemini --model alpha)"
assert_eq "launcher:launch-gemini-omlx <--model> <alpha>" "$out" "AGENTIC_BACKEND=omlx"
out="$(AGENTIC_BACKEND=omlx PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend ollama gemini --model alpha)"
assert_eq "launcher:launch-gemini <--model> <alpha>" "$out" "--backend flag wins over AGENTIC_BACKEND"
pass "backend override paths dispatch to the requested backend"

# 6. --backend value validation: invalid name, repeated flag, missing value.
set +e
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend nope gemini 2>&1)"
status=$?
set -e
assert_eq "2" "$status" "invalid backend exits 2"
assert_contains "$out" "invalid backend 'nope'" "invalid backend diagnosed"
set +e
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend omlx --backend ollama gemini 2>&1)"
status=$?
set -e
assert_eq "2" "$status" "repeated --backend exits 2"
assert_contains "$out" "specified more than once" "repeated --backend diagnosed"
set +e
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend 2>&1)"
status=$?
set -e
assert_eq "2" "$status" "--backend without value exits 2"
assert_contains "$out" "--backend requires a value" "missing backend value diagnosed"
set +e
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend= gemini 2>&1)"
status=$?
set -e
assert_eq "2" "$status" "--backend= (empty) exits 2"
pass "backend flag validation covers all invalid forms"

# 7. Tool-backend guards: claude+ollama rejected; omlx accepts every tool
# including claude.
set +e
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend ollama claude --model alpha 2>&1)"
status=$?
set -e
assert_eq "2" "$status" "claude+ollama exits 2"
assert_contains "$out" "requires the omlx backend" "claude+ollama diagnosed"
for tool in aider claude codex crush deepseek gemini hermes nanocoder openclaw opencode; do
  out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend omlx "$tool" --model alpha)"
  assert_eq "launcher:launch-${tool}-omlx <--model> <alpha>" "$out" "omlx dispatches $tool"
done
pass "claude requires omlx and omlx accepts every advertised tool"

# 8. --model / -m validation: missing value, flag-shaped value, repeated.
set +e
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend ollama gemini --model 2>&1)"
status=$?
set -e
assert_eq "2" "$status" "--model without value exits 2"
assert_contains "$out" "requires a value" "missing --model value diagnosed"
set +e
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend ollama gemini -m 2>&1)"
status=$?
set -e
assert_eq "2" "$status" "-m without value exits 2"
set +e
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend ollama gemini --model --other 2>&1)"
status=$?
set -e
assert_eq "2" "$status" "--model with flag-shaped value exits 2"
set +e
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend ollama gemini --model a --model b 2>&1)"
status=$?
set -e
assert_eq "2" "$status" "--model twice exits 2"
assert_contains "$out" "specified more than once" "repeated --model diagnosed"
pass "model flag validation covers all invalid forms"

# 9. Passthrough args (positional and flag-shaped, before and after --)
# reach the dispatched launcher in order.
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend ollama gemini --model alpha foo --bar baz)"
assert_eq "launcher:launch-gemini <--model> <alpha> <foo> <--bar> <baz>" "$out" "positional and flag passthrough"
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend ollama gemini --model alpha -- --dashed --arg)"
assert_eq "launcher:launch-gemini <--model> <alpha> <--dashed> <--arg>" "$out" "-- forwards dashed args"
pass "extra args forward to the underlying launcher in order"

# 10. '?' resolution: rewritten for ollama, rejected for omlx, and requires
# the resolver on PATH.
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend ollama codex --model 'alpha?' --flag)"
assert_eq "launcher:launch-codex <--model> <alpha-resolved> <--flag>" "$out" "'?' resolved for ollama"
set +e
out="$(PATH="$LAUNCH_PATH" bash "$WRAP/launch" --backend omlx gemini --model 'alpha?' 2>&1)"
status=$?
set -e
assert_eq "2" "$status" "'?' with omlx exits 2"
assert_contains "$out" "requires the ollama backend" "'?' with omlx diagnosed"
set +e
out="$(PATH="$LAUNCH_PATH_NORES" bash "$WRAP/launch" --backend ollama codex --model 'alpha?' 2>&1)"
status=$?
set -e
assert_eq "2" "$status" "'?' with no resolver exits 2"
assert_contains "$out" "ollama-model-resolver" "missing resolver diagnosed"
pass "'?' resolution and its guards"

# 11. launch reached via a symlink still resolves SCRIPT_DIR to the real
# directory and finds sibling launchers.
ALIAS="$TMP/alias"
mkdir -p "$ALIAS"
ln -s "$WRAP/launch" "$ALIAS/launch"
out="$(PATH="$LAUNCH_PATH" bash "$ALIAS/launch" --backend ollama gemini --model alpha)"
assert_eq "launcher:launch-gemini <--model> <alpha>" "$out" "symlinked launch dispatches"
pass "launch reached via symlink resolves SCRIPT_DIR safely"

# 12. Direct launchers accept -m and --model= without losing backend URL state.
DIRECT="$TMP/direct"
DIRECT_BIN="$TMP/direct-bin"
mkdir -p "$DIRECT" "$DIRECT_BIN" "$TMP/cache"
cp "$ROOT/bin/launch-hermes" "$ROOT/bin/_ollama-ensure.sh" \
  "$ROOT/bin/_launcher-common.sh" "$DIRECT/"
copy_lock_runtime "$DIRECT"
chmod 755 "$DIRECT/launch-hermes"
make_fake_command "$DIRECT_BIN/curl" \
  'printf "%s" '\''{"models":[{"name":"alpha:latest"},{"name":"beta:latest"}]}'\'''
make_fake_command "$DIRECT_BIN/hermes-agent" \
  'printf "base=%s key=%s" "$OPENAI_BASE_URL" "$OPENAI_API_KEY"' \
  'for arg in "$@"; do printf " <%s>" "$arg"; done' \
  'printf "\\n"'
out="$(FLOX_ENV_CACHE="$TMP/cache" PATH="$DIRECT_BIN:/usr/bin:/bin" bash "$DIRECT/launch-hermes" -m alpha --yolo)"
assert_eq "base=http://127.0.0.1:11434/v1 key=ollama <--model> <alpha> <--yolo>" "$out" "direct -m"
out="$(FLOX_ENV_CACHE="$TMP/cache" PATH="$DIRECT_BIN:/usr/bin:/bin" bash "$DIRECT/launch-hermes" --model=beta)"
assert_eq "base=http://127.0.0.1:11434/v1 key=ollama <--model> <beta>" "$out" "direct --model="
pass "dedicated launchers accept all advertised model forms"

# 13. OLLAMA_HOST normalization preserves schemes, paths, and IPv6.
normalize_ollama() {
  OLLAMA_HOST="$1" OLLAMA_PORT="${2:-}" bash -c '
    source "$1"
    ollama_normalize_base_url || exit $?
    printf "%s" "$OLLAMA_BASE_URL"
  ' _ "$ROOT/bin/_ollama-ensure.sh"
}
assert_eq "http://127.0.0.1:11434" "$(normalize_ollama 'http://127.0.0.1:11434')" "http URL"
assert_eq "https://ollama.com:443" "$(normalize_ollama 'https://ollama.com')" "https default port"
assert_eq "https://ollama.example:443/root" "$(normalize_ollama 'https://ollama.example/root/')" "URL path"
assert_eq "http://[::1]:11434/prefix" "$(normalize_ollama '[::1]:11434/prefix')" "bracketed IPv6"
assert_eq "http://[2001:db8::1]:80/api" "$(normalize_ollama 'http://[2001:db8::1]/api')" "IPv6 URL default port"
assert_eq "http://host.test:23456" "$(normalize_ollama 'host.test' '23456')" "separate port override"
set +e
normalize_ollama 'http://host.test:0' >/dev/null 2>&1
status=$?
set -e
assert_eq "1" "$status" "zero Ollama port rejected"
pass "OLLAMA_HOST is normalized as a complete URL"

# 14. Concurrent Ollama ensures serialize the same endpoint/model pull.
OLLAMA_RACE_BIN="$TMP/ollama-race-bin"
OLLAMA_RACE_DIR="$TMP/ollama-race"
OLLAMA_RACE_CACHE="$TMP/ollama-race-cache"
mkdir -p "$OLLAMA_RACE_BIN" "$OLLAMA_RACE_DIR" "$OLLAMA_RACE_CACHE"
make_fake_command "$OLLAMA_RACE_BIN/sync" ':'
make_fake_command "$OLLAMA_RACE_BIN/curl" \
  'url=""' \
  'for arg in "$@"; do case "$arg" in http://*|https://*) url="$arg" ;; esac; done' \
  'lock_counter() { while ! mkdir "$OLLAMA_RACE_DIR/counter.lock" 2>/dev/null; do sleep 0.01; done; }' \
  'unlock_counter() { rmdir "$OLLAMA_RACE_DIR/counter.lock"; }' \
  'case "$url" in' \
  '  */api/tags)' \
  '    lock_counter; n=0; [[ ! -f "$OLLAMA_RACE_DIR/tag-count" ]] || n="$(cat "$OLLAMA_RACE_DIR/tag-count")"; n=$((n+1)); printf "%s" "$n" > "$OLLAMA_RACE_DIR/tag-count"; unlock_counter' \
  '    if [[ ! -e "$OLLAMA_RACE_DIR/present" && "$n" -le 2 ]]; then while [[ "$(cat "$OLLAMA_RACE_DIR/tag-count")" -lt 2 ]]; do sleep 0.01; done; fi' \
  '    if [[ -e "$OLLAMA_RACE_DIR/present" ]]; then printf '\''{"models":[{"name":"alpha:latest"}]}'\''; else printf '\''{"models":[]}'\''; fi' \
  '    ;;' \
  '  */api/pull)' \
  '    lock_counter; n=0; [[ ! -f "$OLLAMA_RACE_DIR/pull-count" ]] || n="$(cat "$OLLAMA_RACE_DIR/pull-count")"; n=$((n+1)); printf "%s" "$n" > "$OLLAMA_RACE_DIR/pull-count"; unlock_counter' \
  '    sleep 0.2; : > "$OLLAMA_RACE_DIR/present"; printf '\''{"status":"success"}\n'\''' \
  '    ;;' \
  '  *) exit 2 ;;' \
  'esac'
export OLLAMA_RACE_DIR
(
  FLOX_ENV_CACHE="$OLLAMA_RACE_CACHE" PATH="$OLLAMA_RACE_BIN:/usr/bin:/bin" \
    bash -c 'source "$1"; ollama_ensure_model alpha http://ollama:11434' _ "$ROOT/bin/_ollama-ensure.sh"
) >"$TMP/ollama-race-1.out" 2>"$TMP/ollama-race-1.err" & or1=$!
(
  FLOX_ENV_CACHE="$OLLAMA_RACE_CACHE" PATH="$OLLAMA_RACE_BIN:/usr/bin:/bin" \
    bash -c 'source "$1"; ollama_ensure_model alpha http://ollama:11434' _ "$ROOT/bin/_ollama-ensure.sh"
) >"$TMP/ollama-race-2.out" 2>"$TMP/ollama-race-2.err" & or2=$!
wait "$or1"
wait "$or2"
assert_file_eq "1" "$OLLAMA_RACE_DIR/pull-count" "one Ollama pull request"
pass "concurrent Ollama ensures issue one pull"

# 15. A crash-surviving Ollama pull intent fails closed while absent and clears
# itself after the requested model becomes visible, without a duplicate POST.
OLLAMA_INTENT_BIN="$TMP/ollama-intent-bin"
OLLAMA_INTENT_CACHE="$TMP/ollama-intent-cache"
OLLAMA_INTENT_PRESENT="$TMP/ollama-intent-present"
OLLAMA_INTENT_POSTS="$TMP/ollama-intent-posts"
mkdir -p "$OLLAMA_INTENT_BIN" "$OLLAMA_INTENT_CACHE/ollama-pulls"
printf '0' > "$OLLAMA_INTENT_POSTS"
ollama_intent_key="$(bash -c 'source "$1"; launcher_profile_key ollama-pull-v2 http://ollama:11434 alpha:latest' _ \
  "$ROOT/bin/_launcher-common.sh")"
ollama_intent_marker="$OLLAMA_INTENT_CACHE/ollama-pulls/${ollama_intent_key}.intent"
printf '%s\n' '{"version":1,"state":"intent","model":"alpha:latest","base":"http://ollama:11434","started_at":1}' \
  > "$ollama_intent_marker"
make_fake_command "$OLLAMA_INTENT_BIN/sync" ':'
make_fake_command "$OLLAMA_INTENT_BIN/curl" \
  'url=""; for arg in "$@"; do case "$arg" in http://*|https://*) url="$arg" ;; esac; done' \
  'case "$url" in' \
  '  */api/tags) if [[ -e "$OLLAMA_INTENT_PRESENT" ]]; then printf '\''{"models":[{"name":"alpha:latest"}]}'\''; else printf '\''{"models":[]}'\''; fi ;;' \
  '  */api/pull) n="$(cat "$OLLAMA_INTENT_POSTS")"; printf "%s" "$((n+1))" > "$OLLAMA_INTENT_POSTS"; printf '\''{"status":"success"}'\'' ;;' \
  '  *) exit 2 ;;' \
  'esac'
export OLLAMA_INTENT_PRESENT OLLAMA_INTENT_POSTS
set +e
FLOX_ENV_CACHE="$OLLAMA_INTENT_CACHE" OLLAMA_PULL_RECOVERY_SECONDS=1 \
  PATH="$OLLAMA_INTENT_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; ollama_ensure_model alpha http://ollama:11434' _ "$ROOT/bin/_ollama-ensure.sh" \
  >"$TMP/ollama-intent.out" 2>"$TMP/ollama-intent.err"
status=$?
set -e
assert_eq "1" "$status" "indeterminate Ollama pull fails closed"
assert_file_eq "0" "$OLLAMA_INTENT_POSTS" "indeterminate Ollama pull issued no duplicate POST"
[[ -f "$ollama_intent_marker" ]] || fail "Ollama intent journal retained while absent"
assert_contains "$(cat "$TMP/ollama-intent.err")" "Refusing a duplicate pull" "Ollama fail-closed diagnostic"
: > "$OLLAMA_INTENT_PRESENT"
FLOX_ENV_CACHE="$OLLAMA_INTENT_CACHE" PATH="$OLLAMA_INTENT_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; ollama_ensure_model alpha http://ollama:11434' _ "$ROOT/bin/_ollama-ensure.sh"
[[ ! -e "$ollama_intent_marker" ]] || fail "Ollama intent cleared after visibility"
assert_file_eq "0" "$OLLAMA_INTENT_POSTS" "visible recovery still issued no pull"
pass "Ollama unknown pull outcomes never duplicate transfers"

# Shared fake sync for durable proxy-state tests.
PROXY_BIN="$TMP/proxy-bin"
mkdir -p "$PROXY_BIN"
make_fake_command "$PROXY_BIN/sync" ':'

# 16. A durable incomplete proxy transition always forces recovery restart.
PROXY_CACHE="$TMP/proxy-crash-cache"
PROXY_CURRENT="$TMP/proxy-crash-current"
PROXY_RESTARTS="$TMP/proxy-crash-restarts"
mkdir -p "$PROXY_CACHE"
printf '%s' old-model > "$PROXY_CURRENT"
printf '%s' new-model > "$PROXY_CACHE/proxy.model"
printf '%s' old-model > "$PROXY_CACHE/proxy.model.committed"
printf '%s\n' '{"version":1,"target":"new-model","previous_present":true,"previous":"old-model"}' \
  > "$PROXY_CACHE/proxy.model.transition"
printf '0' > "$PROXY_RESTARTS"
make_fake_command "$PROXY_BIN/curl" 'exit 0'
make_fake_command "$PROXY_BIN/flox" \
  'n="$(cat "$PROXY_RESTARTS")"; printf "%s" "$((n+1))" > "$PROXY_RESTARTS"' \
  'printf "%s" "$(cat "$FLOX_ENV_CACHE/proxy.model")" > "$PROXY_CURRENT"'
export PROXY_CURRENT PROXY_RESTARTS
FLOX_ENV_CACHE="$PROXY_CACHE" PATH="$PROXY_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; proxy_ensure_model proxy new-model 127.0.0.1:8081 "backend=test"' _ "$ROOT/bin/_proxy-ensure.sh"
assert_file_eq "1" "$PROXY_RESTARTS" "incomplete transition restarted"
assert_file_eq "new-model" "$PROXY_CURRENT" "live proxy recovered to target"
assert_eq "2:new-model" "$(jq -r '"\(.version):\(.model)"' "$PROXY_CACHE/proxy.model.committed")" "target committed after restart"
[[ ! -e "$PROXY_CACHE/proxy.model.transition" ]] || fail "proxy transition marker removed"
pass "proxy transitions recover crash-consistently"

# 17. Desired state plus health is not accepted when committed state disagrees.
PROXY_CACHE2="$TMP/proxy-disagree-cache"
PROXY_CURRENT2="$TMP/proxy-disagree-current"
PROXY_RESTARTS2="$TMP/proxy-disagree-restarts"
mkdir -p "$PROXY_CACHE2"
printf '%s' old-model > "$PROXY_CURRENT2"
printf '%s' new-model > "$PROXY_CACHE2/proxy.model"
printf '%s' old-model > "$PROXY_CACHE2/proxy.model.committed"
printf '0' > "$PROXY_RESTARTS2"
make_fake_command "$PROXY_BIN/flox" \
  'n="$(cat "$PROXY_RESTARTS2")"; printf "%s" "$((n+1))" > "$PROXY_RESTARTS2"' \
  'printf "%s" "$(cat "$FLOX_ENV_CACHE/proxy.model")" > "$PROXY_CURRENT2"'
export PROXY_CURRENT2 PROXY_RESTARTS2
FLOX_ENV_CACHE="$PROXY_CACHE2" PATH="$PROXY_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; proxy_ensure_model proxy new-model 127.0.0.1:8081 "backend=test"' _ "$ROOT/bin/_proxy-ensure.sh"
assert_file_eq "1" "$PROXY_RESTARTS2" "disagreeing committed state restarted"
assert_file_eq "new-model" "$PROXY_CURRENT2" "desired state applied"
pass "proxy desired state is never mistaken for observed state"

# 18. Proxy transitions are serialized across concurrent model switches.
PROXY_CACHE3="$TMP/proxy-concurrent-cache"
PROXY_LOG3="$TMP/proxy-concurrent.log"
PROXY_CURRENT3="$TMP/proxy-concurrent.current"
mkdir -p "$PROXY_CACHE3"
printf '%s' old > "$PROXY_CURRENT3"
printf '%s' old > "$PROXY_CACHE3/proxy.model"
printf '%s' old > "$PROXY_CACHE3/proxy.model.committed"
make_fake_command "$PROXY_BIN/flox" \
  'model="$(cat "$FLOX_ENV_CACHE/proxy.model")"' \
  'printf "start:%s\\n" "$model" >> "$PROXY_LOG3"' \
  'sleep 0.2' \
  'printf "%s" "$model" > "$PROXY_CURRENT3"' \
  'printf "end:%s\\n" "$model" >> "$PROXY_LOG3"'
export PROXY_LOG3 PROXY_CURRENT3
(
  FLOX_ENV_CACHE="$PROXY_CACHE3" PATH="$PROXY_BIN:/usr/bin:/bin" \
    bash -c 'source "$1"; proxy_ensure_model proxy alpha 127.0.0.1:8081 "backend=test"' _ "$ROOT/bin/_proxy-ensure.sh"
) & p1=$!
(
  FLOX_ENV_CACHE="$PROXY_CACHE3" PATH="$PROXY_BIN:/usr/bin:/bin" \
    bash -c 'source "$1"; proxy_ensure_model proxy beta 127.0.0.1:8081 "backend=test"' _ "$ROOT/bin/_proxy-ensure.sh"
) & p2=$!
wait "$p1"
wait "$p2"
assert_eq "4" "$(wc -l < "$PROXY_LOG3" | tr -d ' ')" "proxy restart log length"
first="$(sed -n '1p' "$PROXY_LOG3")"; second="$(sed -n '2p' "$PROXY_LOG3")"
third="$(sed -n '3p' "$PROXY_LOG3")"; fourth="$(sed -n '4p' "$PROXY_LOG3")"
assert_eq "end:${first#start:}" "$second" "first proxy transaction contiguous"
assert_eq "end:${third#start:}" "$fourth" "second proxy transaction contiguous"
pass "proxy model switches are serialized"

# 19. Failed proxy switches restore the last durably committed state.
ROLL_CACHE="$TMP/proxy-roll-cache"
ROLL_CURRENT="$TMP/proxy-roll-current"
ROLL_LOG="$TMP/proxy-roll.log"
ROLL_MARK="$TMP/proxy-roll.failed"
mkdir -p "$ROLL_CACHE"
printf '%s' old > "$ROLL_CURRENT"
printf '%s' old > "$ROLL_CACHE/proxy.model"
roll_runtime="$(bash -c 'source "$1"; launcher_profile_key proxy-runtime-v2 proxy http://127.0.0.1:8081 backend=test' _ "$ROOT/bin/_launcher-common.sh")"
roll_identity="$(bash -c 'source "$1"; launcher_profile_key proxy-applied-v2 proxy old "$2"' _ "$ROOT/bin/_launcher-common.sh" "$roll_runtime")"
jq -cn --arg runtime "$roll_runtime" --arg identity "$roll_identity" \
  '{version:2,service:"proxy",model:"old",listen:"http://127.0.0.1:8081",runtime_id:$runtime,identity:$identity}' \
  > "$ROLL_CACHE/proxy.model.committed"
make_fake_command "$PROXY_BIN/flox" \
  'model="$(cat "$FLOX_ENV_CACHE/proxy.model")"' \
  'printf "%s\\n" "$model" >> "$ROLL_LOG"' \
  'if [[ "$model" == bad && ! -e "$ROLL_MARK" ]]; then : > "$ROLL_MARK"; exit 1; fi' \
  'printf "%s" "$model" > "$ROLL_CURRENT"'
export ROLL_LOG ROLL_MARK ROLL_CURRENT
set +e
FLOX_ENV_CACHE="$ROLL_CACHE" PATH="$PROXY_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; proxy_ensure_model proxy bad 127.0.0.1:8081 "backend=test"' _ "$ROOT/bin/_proxy-ensure.sh" \
  >"$TMP/proxy-roll.out" 2>"$TMP/proxy-roll.err"
status=$?
set -e
assert_eq "1" "$status" "failed proxy switch returns failure"
assert_file_eq "old" "$ROLL_CACHE/proxy.model" "proxy desired state rolled back"
assert_eq "old" "$(jq -r '.model' "$ROLL_CACHE/proxy.model.committed")" "committed state preserved"
assert_file_eq "old" "$ROLL_CURRENT" "live proxy restored"
assert_eq $'bad\nold' "$(cat "$ROLL_LOG")" "rollback restart sequence"
[[ ! -e "$ROLL_CACHE/proxy.model.transition" ]] || fail "successful rollback clears transition"
assert_contains "$(cat "$TMP/proxy-roll.err")" "was restored" "rollback diagnostic is accurate"
pass "proxy rollback is checked and accurately reported"

# 20. Proxy service restart has a bounded execution deadline.
TIMEOUT_CACHE="$TMP/proxy-timeout-cache"
TIMEOUT_BIN="$TMP/proxy-timeout-bin"
mkdir -p "$TIMEOUT_CACHE" "$TIMEOUT_BIN"
make_fake_command "$TIMEOUT_BIN/sync" ':'
make_fake_command "$TIMEOUT_BIN/curl" 'exit 0'
TIMEOUT_PIDS="$TMP/proxy-timeout-pids"
make_fake_command "$TIMEOUT_BIN/flox" \
  'sleep 20 & child=$!' \
  'printf "%s %s\n" "$$" "$child" > "$TIMEOUT_PIDS"' \
  'wait "$child"'
export TIMEOUT_PIDS
start_time="$(date +%s)"
set +e
FLOX_ENV_CACHE="$TIMEOUT_CACHE" PROXY_RESTART_TIMEOUT_SECONDS=1 \
  PATH="$TIMEOUT_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; proxy_ensure_model proxy alpha 127.0.0.1:8081 "backend=test"' _ "$ROOT/bin/_proxy-ensure.sh" \
  >"$TMP/proxy-timeout.out" 2>"$TMP/proxy-timeout.err"
status=$?
set -e
elapsed=$(( $(date +%s) - start_time ))
assert_eq "1" "$status" "restart timeout fails"
[[ "$elapsed" -lt 8 ]] || fail "proxy restart deadline bounded"
assert_contains "$(cat "$TMP/proxy-timeout.err")" "timed out restarting service" "restart timeout diagnostic"
[[ -e "$TIMEOUT_CACHE/proxy.model.transition" ]] || fail "failed transition remains recoverable"
read -r timeout_parent timeout_child < "$TIMEOUT_PIDS"
assert_not_live "$timeout_parent" "timed-out restart parent remained live"
assert_not_live "$timeout_child" "timed-out restart descendant remained live"
pass "proxy restarts cannot block indefinitely or leak descendants"

# 21. Atomic publication never exposes mixed config content.
ATOMIC_DIR="$TMP/atomic"
mkdir -p "$ATOMIC_DIR"
awk 'BEGIN { for (i=0; i<20000; i++) printf "A" }' > "$ATOMIC_DIR/a"
awk 'BEGIN { for (i=0; i<20000; i++) printf "B" }' > "$ATOMIC_DIR/b"
for _ in 1 2 3 4 5; do
  (source "$ROOT/bin/_launcher-common.sh"; launcher_atomic_write_file "$ATOMIC_DIR/config" 600 < "$ATOMIC_DIR/a") & a=$!
  (source "$ROOT/bin/_launcher-common.sh"; launcher_atomic_write_file "$ATOMIC_DIR/config" 600 < "$ATOMIC_DIR/b") & b=$!
  wait "$a"; wait "$b"
  cmp -s "$ATOMIC_DIR/config" "$ATOMIC_DIR/a" || cmp -s "$ATOMIC_DIR/config" "$ATOMIC_DIR/b" \
    || fail "atomic config publication"
done
pass "config publication is atomic under contention"

# 22. Atomic writers reject pre-existing symlinks and directories.
GUARD_DIR="$TMP/guard"
mkdir -p "$GUARD_DIR/config-dir"
printf '%s' original > "$GUARD_DIR/victim"
ln -s "$GUARD_DIR/victim" "$GUARD_DIR/config-link"
set +e
printf '%s' replacement | bash -c 'source "$1"; launcher_atomic_write_file "$2" 600' _ \
  "$ROOT/bin/_launcher-common.sh" "$GUARD_DIR/config-dir" >/dev/null 2>&1
dir_status=$?
printf '%s' replacement | bash -c 'source "$1"; launcher_atomic_write_file "$2" 600' _ \
  "$ROOT/bin/_launcher-common.sh" "$GUARD_DIR/config-link" >/dev/null 2>&1
link_status=$?
set -e
assert_eq "1" "$dir_status" "directory target rejection"
assert_eq "1" "$link_status" "symlink target rejection"
assert_file_eq "original" "$GUARD_DIR/victim" "symlink target untouched"
pass "config publication rejects redirected targets"

# 23. Atomic replacement uses the native rename helper, not command-line mv
# directory semantics. A hostile mv shim must never be reached.
MV_RACE_BIN="$TMP/mv-race-bin"
MV_RACE_DIR="$TMP/mv-race"
MV_RACE_CALLS="$TMP/mv-race.calls"
mkdir -p "$MV_RACE_BIN" "$MV_RACE_DIR"
printf '0' > "$MV_RACE_CALLS"
make_fake_command "$MV_RACE_BIN/mv" \
  'n="$(cat "$MV_RACE_CALLS")"' \
  'printf "%s" "$((n+1))" > "$MV_RACE_CALLS"' \
  'target="${@: -1}"' \
  'rm -f "$target"' \
  'mkdir -p "$target"' \
  'exec /bin/mv "$@"'
export MV_RACE_CALLS
printf '%s' old > "$MV_RACE_DIR/target"
printf '%s' new | PATH="$MV_RACE_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; launcher_atomic_write_file "$2" 600' _ \
  "$ROOT/bin/_launcher-common.sh" "$MV_RACE_DIR/target"
assert_file_eq "new" "$MV_RACE_DIR/target" "native rename publication content"
assert_file_eq "0" "$MV_RACE_CALLS" "command-line mv was not invoked"
pass "atomic writer publishes through descriptor-bound native rename"

# 24. Same-model OpenCode launches at different Ollama endpoints do not collide.
PROFILE_DIRECT="$TMP/profile-direct"
PROFILE_BIN="$TMP/profile-bin"
PROFILE_CACHE="$TMP/profile-cache"
mkdir -p "$PROFILE_DIRECT" "$PROFILE_BIN" "$PROFILE_CACHE"
cp "$ROOT/bin/launch-opencode" "$ROOT/bin/_ollama-ensure.sh" \
  "$ROOT/bin/_launcher-common.sh" "$PROFILE_DIRECT/"
copy_lock_runtime "$PROFILE_DIRECT"
chmod 755 "$PROFILE_DIRECT/launch-opencode"
make_fake_command "$PROFILE_BIN/curl" 'printf '\''{"models":[{"name":"alpha:latest"}]}'\'''
make_fake_command "$PROFILE_BIN/opencode" \
  'sleep 0.2' \
  'printf "root=%s base=%s\\n" "$XDG_CONFIG_HOME" "$(jq -r .provider.ollama.options.baseURL "$XDG_CONFIG_HOME/opencode/opencode.json")"'
(
  OLLAMA_HOST='http://host-one:11434/root' FLOX_ENV_CACHE="$PROFILE_CACHE" PATH="$PROFILE_BIN:/usr/bin:/bin" \
    bash "$PROFILE_DIRECT/launch-opencode" --model alpha > "$TMP/profile-one.out"
) & po1=$!
(
  OLLAMA_HOST='https://host-two:22468/api' FLOX_ENV_CACHE="$PROFILE_CACHE" PATH="$PROFILE_BIN:/usr/bin:/bin" \
    bash "$PROFILE_DIRECT/launch-opencode" --model alpha > "$TMP/profile-two.out"
) & po2=$!
wait "$po1"; wait "$po2"
one="$(cat "$TMP/profile-one.out")"; two="$(cat "$TMP/profile-two.out")"
assert_contains "$one" "base=http://host-one:11434/root/v1" "first endpoint retained"
assert_contains "$two" "base=https://host-two:22468/api/v1" "second endpoint retained"
one_root="${one#root=}"; one_root="${one_root%% base=*}"
two_root="${two#root=}"; two_root="${two_root%% base=*}"
[[ "$one_root" != "$two_root" ]] || fail "Ollama endpoint profile roots differ"
assert_eq "2" "$(find "$PROFILE_CACHE/opencode-profiles" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "two endpoint profiles"
pass "Ollama profiles bind complete endpoint configuration"

# 25. Same-model OpenCode launches at different oMLX endpoints do not collide.
OMLX_PROFILE_DIRECT="$TMP/omlx-profile-direct"
OMLX_PROFILE_BIN="$TMP/omlx-profile-bin"
OMLX_PROFILE_CACHE="$TMP/omlx-profile-cache"
OMLX_PROFILE_HOME="$TMP/omlx-profile-home"
mkdir -p "$OMLX_PROFILE_DIRECT" "$OMLX_PROFILE_BIN" "$OMLX_PROFILE_CACHE" "$OMLX_PROFILE_HOME/.omlx"
printf '%s' '{"auth":{"api_key":"secret-key"}}' > "$OMLX_PROFILE_HOME/.omlx/settings.json"
cp "$ROOT/bin/launch-opencode-omlx" "$ROOT/bin/_omlx-ensure.sh" \
  "$ROOT/bin/_launcher-common.sh" "$OMLX_PROFILE_DIRECT/"
copy_lock_runtime "$OMLX_PROFILE_DIRECT"
chmod 755 "$OMLX_PROFILE_DIRECT/launch-opencode-omlx"
make_fake_command "$OMLX_PROFILE_BIN/curl" \
  'url=""; wants_code=false; for arg in "$@"; do case "$arg" in http://*|https://*) url="$arg" ;; *"%{http_code}"*) wants_code=true ;; esac; done' \
  'case "$url" in' \
  '  */admin/api/login) printf "200" ;;' \
  '  */admin/api/models) printf '\''{"models":[{"id":"Model-4bit","display_name":"org/Model-4bit","source_repo_id":"org/Model-4bit"}]}'\'' ;;' \
  '  */v1/models) if [[ "$wants_code" == true ]]; then printf "200"; else printf '\''{"data":[{"id":"Model-4bit"}]}'\''; fi ;;' \
  '  *) exit 2 ;;' \
  'esac' 
make_fake_command "$OMLX_PROFILE_BIN/opencode" \
  'sleep 0.2' \
  'printf "root=%s base=%s\\n" "$XDG_CONFIG_HOME" "$(jq -r .provider.omlx.options.baseURL "$XDG_CONFIG_HOME/opencode/opencode.json")"'
(
  HOME="$OMLX_PROFILE_HOME" OMLX_HOST='host-one' OMLX_PORT=8000 \
    FLOX_ENV_CACHE="$OMLX_PROFILE_CACHE" PATH="$OMLX_PROFILE_BIN:/usr/bin:/bin" \
    bash "$OMLX_PROFILE_DIRECT/launch-opencode-omlx" --model org/Model-4bit > "$TMP/omlx-profile-one.out"
) & opo1=$!
(
  HOME="$OMLX_PROFILE_HOME" OMLX_HOST='host-two' OMLX_PORT=9000 \
    FLOX_ENV_CACHE="$OMLX_PROFILE_CACHE" PATH="$OMLX_PROFILE_BIN:/usr/bin:/bin" \
    bash "$OMLX_PROFILE_DIRECT/launch-opencode-omlx" --model org/Model-4bit > "$TMP/omlx-profile-two.out"
) & opo2=$!
wait "$opo1"; wait "$opo2"
omlx_one="$(cat "$TMP/omlx-profile-one.out")"; omlx_two="$(cat "$TMP/omlx-profile-two.out")"
assert_contains "$omlx_one" "base=http://host-one:8000/v1" "first oMLX endpoint retained"
assert_contains "$omlx_two" "base=http://host-two:9000/v1" "second oMLX endpoint retained"
omlx_one_root="${omlx_one#root=}"; omlx_one_root="${omlx_one_root%% base=*}"
omlx_two_root="${omlx_two#root=}"; omlx_two_root="${omlx_two_root%% base=*}"
[[ "$omlx_one_root" != "$omlx_two_root" ]] || fail "oMLX endpoint profile roots differ"
pass "oMLX profiles bind endpoint and credential identity"

# 26. Every model-specific profile key includes all configuration dependencies.
grep -F 'launcher_profile_key "opencode-ollama" "$MODEL" "$OLLAMA_BASE_URL"' "$ROOT/bin/launch-opencode" >/dev/null
grep -F 'launcher_profile_key "openclaw-ollama" "$MODEL" "$OLLAMA_BASE_URL"' "$ROOT/bin/launch-openclaw" >/dev/null
grep -F 'launcher_profile_key "crush-ollama" "$MODEL" "$OLLAMA_BASE_URL" "$PROXY_BASE_URL"' "$ROOT/bin/launch-crush" >/dev/null
grep -F -- '--arg base "${PROXY_BASE_URL}/v1"' "$ROOT/bin/launch-crush" >/dev/null
grep -F 'launcher_profile_key "opencode-omlx" "$MODEL" "$OMLX_MODEL_ID" "$OMLX_BASE_URL" "$OMLX_API_KEY"' "$ROOT/bin/launch-opencode-omlx" >/dev/null
grep -F 'launcher_profile_key "openclaw-omlx" "$MODEL" "$OMLX_MODEL_ID" "$OMLX_BASE_URL" "$OMLX_API_KEY"' "$ROOT/bin/launch-openclaw-omlx" >/dev/null
grep -F 'launcher_profile_key "crush-omlx" "$MODEL" "$OMLX_MODEL_ID" "$OMLX_BASE_URL" "$OMLX_API_KEY"' "$ROOT/bin/launch-crush-omlx" >/dev/null
pass "profile identity covers model, endpoint, proxy, and credential inputs"

# 27. oMLX model discovery distinguishes absent, unreachable, and malformed.
OMLX_STATUS_BIN="$TMP/omlx-status-bin"
mkdir -p "$OMLX_STATUS_BIN"
make_fake_command "$OMLX_STATUS_BIN/curl" \
  '[[ "${MODEL_CURL_FAIL:-0}" != 1 ]] || exit 7' \
  'printf "%s" "$MODEL_RESPONSE"'
set +e
MODEL_RESPONSE='{"data":[{"id":"Model-4bit"}]}' PATH="$OMLX_STATUS_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; _omlx_model_is_loaded Model-4bit http://omlx key' _ "$ROOT/bin/_omlx-ensure.sh"
loaded_status=$?
MODEL_RESPONSE='{"data":[{"id":"Model-4bit"}]}' PATH="$OMLX_STATUS_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; _omlx_model_is_loaded org/Model-4bit http://omlx key' _ "$ROOT/bin/_omlx-ensure.sh"
provenance_status=$?
MODEL_RESPONSE='{"data":[{"id":"other"}]}' PATH="$OMLX_STATUS_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; _omlx_model_is_loaded org/Model-4bit http://omlx key' _ "$ROOT/bin/_omlx-ensure.sh"
missing_status=$?
MODEL_RESPONSE='not-json' PATH="$OMLX_STATUS_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; _omlx_model_is_loaded org/Model-4bit http://omlx key' _ "$ROOT/bin/_omlx-ensure.sh"
malformed_status=$?
MODEL_CURL_FAIL=1 MODEL_RESPONSE='' PATH="$OMLX_STATUS_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; _omlx_model_is_loaded org/Model-4bit http://omlx key' _ "$ROOT/bin/_omlx-ensure.sh"
unreachable_status=$?
set -e
assert_eq "0" "$loaded_status" "oMLX slashless loaded status"
assert_eq "4" "$provenance_status" "oMLX repository requires provenance"
assert_eq "1" "$missing_status" "oMLX missing status"
assert_eq "3" "$malformed_status" "oMLX malformed status"
assert_eq "2" "$unreachable_status" "oMLX unreachable status"
pass "oMLX model discovery has explicit result classes"

# 28. oMLX admin-login transport failures produce an actionable diagnostic.
OMLX_FAIL_BIN="$TMP/omlx-fail-bin"
OMLX_FAIL_CACHE="$TMP/omlx-fail-cache"
mkdir -p "$OMLX_FAIL_BIN" "$OMLX_FAIL_CACHE"
make_fake_command "$OMLX_FAIL_BIN/sync" ':'
make_fake_command "$OMLX_FAIL_BIN/curl" \
  'url=""; for arg in "$@"; do case "$arg" in http://*|https://*) url="$arg" ;; esac; done' \
  'case "$url" in' \
  '  */v1/models) printf '\''{"data":[]}'\'' ;;' \
  '  */admin/api/login) echo "curl: (7) connection refused" >&2; exit 7 ;;' \
  '  *) exit 2 ;;' \
  'esac'
set +e
FLOX_ENV_CACHE="$OMLX_FAIL_CACHE" PATH="$OMLX_FAIL_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; _omlx_download_model org/model http://omlx key token' _ "$ROOT/bin/_omlx-ensure.sh" \
  >"$TMP/omlx-login.out" 2>"$TMP/omlx-login.err"
status=$?
set -e
assert_eq "1" "$status" "oMLX login connection failure"
assert_contains "$(cat "$TMP/omlx-login.err")" "could not contact the oMLX admin API" "oMLX login custom error"
assert_contains "$(cat "$TMP/omlx-login.err")" "connection refused" "oMLX curl detail preserved"
pass "oMLX admin-login failures are never silent"

# 29. A completed oMLX task cannot succeed before the model is visible.
OMLX_ABSENT_BIN="$TMP/omlx-absent-bin"
OMLX_ABSENT_CACHE="$TMP/omlx-absent-cache"
mkdir -p "$OMLX_ABSENT_BIN" "$OMLX_ABSENT_CACHE"
make_fake_command "$OMLX_ABSENT_BIN/sync" ':'
make_fake_command "$OMLX_ABSENT_BIN/curl" \
  'url=""; for arg in "$@"; do case "$arg" in http://*|https://*) url="$arg" ;; esac; done' \
  'case "$url" in' \
  '  */v1/models) printf '\''{"data":[]}'\'' ;;' \
  '  */admin/api/login) printf "200" ;;' \
  '  */admin/api/models) printf '\''{"models":[]}'\'' ;;' \
  '  */admin/api/hf/download) printf '\''{"success":true,"task":{"task_id":"task-1","repo_id":"org/model"}}'\'' ;;' \
  '  */admin/api/hf/tasks) printf '\''{"tasks":[{"task_id":"task-1","repo_id":"org/model","status":"completed","progress":100}]}'\'' ;;' \
  '  *) exit 2 ;;' \
  'esac'
set +e
FLOX_ENV_CACHE="$OMLX_ABSENT_CACHE" OMLX_MODEL_VISIBLE_TIMEOUT_SECONDS=1 OMLX_MODEL_VISIBLE_POLL_SECONDS=0.1 \
  PATH="$OMLX_ABSENT_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; _omlx_download_model org/model http://omlx key token' _ "$ROOT/bin/_omlx-ensure.sh" \
  >"$TMP/omlx-absent.out" 2>"$TMP/omlx-absent.err"
status=$?
set -e
assert_eq "1" "$status" "completed but absent model fails"
assert_contains "$(cat "$TMP/omlx-absent.err")" "never appeared in /v1/models" "absent postcondition diagnostic"
pass "oMLX completion is verified against model discovery"

# 30. oMLX succeeds after task completion and delayed model registration.
OMLX_VISIBLE_BIN="$TMP/omlx-visible-bin"
OMLX_VISIBLE_CACHE="$TMP/omlx-visible-cache"
OMLX_VISIBLE_STATE="$TMP/omlx-visible-state"
mkdir -p "$OMLX_VISIBLE_BIN" "$OMLX_VISIBLE_CACHE"
make_fake_command "$OMLX_VISIBLE_BIN/sync" ':'
make_fake_command "$OMLX_VISIBLE_BIN/curl" \
  'url=""; for arg in "$@"; do case "$arg" in http://*|https://*) url="$arg" ;; esac; done' \
  'case "$url" in' \
  '  */v1/models) if [[ -e "$OMLX_VISIBLE_STATE" ]]; then printf '\''{"data":[{"id":"model"}]}'\''; else printf '\''{"data":[]}'\''; fi ;;' \
  '  */admin/api/login) printf "200" ;;' \
  '  */admin/api/models) if [[ -e "$OMLX_VISIBLE_STATE" ]]; then printf '\''{"models":[{"id":"model","display_name":"org/model","source_repo_id":"org/model"}]}'\''; else printf '\''{"models":[]}'\''; fi ;;' \
  '  */admin/api/hf/download) printf '\''{"success":true,"task":{"task_id":"task-2","repo_id":"org/model"}}'\'' ;;' \
  '  */admin/api/hf/tasks) : > "$OMLX_VISIBLE_STATE"; printf '\''{"tasks":[{"task_id":"task-2","repo_id":"org/model","status":"completed","progress":100}]}'\'' ;;' \
  '  *) exit 2 ;;' \
  'esac'
export OMLX_VISIBLE_STATE
FLOX_ENV_CACHE="$OMLX_VISIBLE_CACHE" OMLX_MODEL_VISIBLE_TIMEOUT_SECONDS=2 OMLX_MODEL_VISIBLE_POLL_SECONDS=0.1 \
  PATH="$OMLX_VISIBLE_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; _omlx_download_model org/model http://omlx key token' _ "$ROOT/bin/_omlx-ensure.sh" \
  >"$TMP/omlx-visible.out" 2>"$TMP/omlx-visible.err"
pass "oMLX ensure waits through delayed registration"

# 31. Concurrent oMLX ensures for one endpoint/model submit one download.
OMLX_LOCK_BIN="$TMP/omlx-lock-bin"
OMLX_LOCK_CACHE="$TMP/omlx-lock-cache"
OMLX_LOCK_STATE="$TMP/omlx-lock-state"
OMLX_DOWNLOAD_COUNT="$TMP/omlx-download-count"
mkdir -p "$OMLX_LOCK_BIN" "$OMLX_LOCK_CACHE"
printf '0' > "$OMLX_DOWNLOAD_COUNT"
make_fake_command "$OMLX_LOCK_BIN/sync" ':'
make_fake_command "$OMLX_LOCK_BIN/curl" \
  'url=""; for arg in "$@"; do case "$arg" in http://*|https://*) url="$arg" ;; esac; done' \
  'case "$url" in' \
  '  */v1/models) if [[ -e "$OMLX_LOCK_STATE" ]]; then printf '\''{"data":[{"id":"model"}]}'\''; else printf '\''{"data":[]}'\''; fi ;;' \
  '  */admin/api/login) printf "200" ;;' \
  '  */admin/api/models) if [[ -e "$OMLX_LOCK_STATE" ]]; then printf '\''{"models":[{"id":"model","display_name":"org/model","source_repo_id":"org/model"}]}'\''; else printf '\''{"models":[]}'\''; fi ;;' \
  '  */admin/api/hf/download) n="$(cat "$OMLX_DOWNLOAD_COUNT")"; printf "%s" "$((n+1))" > "$OMLX_DOWNLOAD_COUNT"; printf '\''{"success":true,"task":{"task_id":"task-lock","repo_id":"org/model"}}'\'' ;;' \
  '  */admin/api/hf/tasks) sleep 0.2; : > "$OMLX_LOCK_STATE"; printf '\''{"tasks":[{"task_id":"task-lock","repo_id":"org/model","status":"completed","progress":100}]}'\'' ;;' \
  '  *) exit 2 ;;' \
  'esac'
export OMLX_LOCK_STATE OMLX_DOWNLOAD_COUNT
(
  FLOX_ENV_CACHE="$OMLX_LOCK_CACHE" OMLX_DOWNLOAD_POLL_SECONDS=0.1 OMLX_MODEL_VISIBLE_POLL_SECONDS=0.1 \
    PATH="$OMLX_LOCK_BIN:/usr/bin:/bin" \
    bash -c 'source "$1"; _omlx_download_model org/model http://omlx key token' _ "$ROOT/bin/_omlx-ensure.sh"
) >"$TMP/omlx-lock-1.out" 2>"$TMP/omlx-lock-1.err" & ol1=$!
(
  FLOX_ENV_CACHE="$OMLX_LOCK_CACHE" OMLX_DOWNLOAD_POLL_SECONDS=0.1 OMLX_MODEL_VISIBLE_POLL_SECONDS=0.1 \
    PATH="$OMLX_LOCK_BIN:/usr/bin:/bin" \
    bash -c 'source "$1"; _omlx_download_model org/model http://omlx key token' _ "$ROOT/bin/_omlx-ensure.sh"
) >"$TMP/omlx-lock-2.out" 2>"$TMP/omlx-lock-2.err" & ol2=$!
wait "$ol1"; wait "$ol2"
assert_file_eq "1" "$OMLX_DOWNLOAD_COUNT" "one oMLX download request"
pass "concurrent oMLX ensures are endpoint-and-model idempotent"

# 32. Interrupting an active oMLX download cancels the server task and unlocks.
OMLX_CANCEL_BIN="$TMP/omlx-cancel-bin"
OMLX_CANCEL_CACHE="$TMP/omlx-cancel-cache"
OMLX_CANCEL_STARTED="$TMP/omlx-cancel-started"
OMLX_CANCEL_LOG="$TMP/omlx-cancel.log"
mkdir -p "$OMLX_CANCEL_BIN" "$OMLX_CANCEL_CACHE"
make_fake_command "$OMLX_CANCEL_BIN/sync" ':'
make_fake_command "$OMLX_CANCEL_BIN/curl" \
  'url=""; for arg in "$@"; do case "$arg" in http://*|https://*) url="$arg" ;; esac; done' \
  'case "$url" in' \
  '  */v1/models) printf '\''{"data":[]}'\'' ;;' \
  '  */admin/api/login) printf "200" ;;' \
  '  */admin/api/models) printf '\''{"models":[]}'\'' ;;' \
  '  */admin/api/hf/download) : > "$OMLX_CANCEL_STARTED"; printf '\''{"success":true,"task":{"task_id":"task-cancel","repo_id":"org/model"}}'\'' ;;' \
  '  */admin/api/hf/tasks) printf '\''{"tasks":[{"task_id":"task-cancel","repo_id":"org/model","status":"downloading","progress":10}]}'\'' ;;' \
  '  */admin/api/hf/cancel/task-cancel) printf "cancel\\n" >> "$OMLX_CANCEL_LOG"; printf '\''{"success":true}'\'' ;;' \
  '  *) exit 2 ;;' \
  'esac'
export OMLX_CANCEL_STARTED OMLX_CANCEL_LOG
FLOX_ENV_CACHE="$OMLX_CANCEL_CACHE" OMLX_DOWNLOAD_POLL_SECONDS=0.2 \
  PATH="$OMLX_CANCEL_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; _omlx_download_model org/model http://omlx key token' _ "$ROOT/bin/_omlx-ensure.sh" \
  >"$TMP/omlx-cancel.out" 2>"$TMP/omlx-cancel.err" & cancel_pid=$!
cancel_marker=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  cancel_marker="$(find "$OMLX_CANCEL_CACHE" -name '*.task' -type f -print -quit 2>/dev/null || true)"
  if [[ -n "$cancel_marker" ]]       && [[ "$(jq -r '.state // empty' "$cancel_marker" 2>/dev/null || true)" == "active" ]]; then
    break
  fi
  sleep 0.1
done
[[ -e "$OMLX_CANCEL_STARTED" ]] || fail "oMLX cancel test started server task"
[[ -n "$cancel_marker" ]] || fail "oMLX cancel test durably journaled active task"
kill -TERM "$cancel_pid"
set +e
wait "$cancel_pid"
status=$?
set -e
assert_eq "143" "$status" "interrupted oMLX helper status"
assert_eq "1" "$(wc -l < "$OMLX_CANCEL_LOG" | tr -d ' ')" "server cancellation request"
cancel_lock="$(find "$OMLX_CANCEL_CACHE" -name '*.lock' -type f -print -quit)"
[[ -n "$cancel_lock" ]] || fail "persistent oMLX lock inode exists"
bash -c '
  source "$1"
  LAUNCHER_LOCK_FD=""
  launcher_lock_acquire "$2" 1 120 reacquire
  launcher_lock_release
' _ "$ROOT/bin/_launcher-common.sh" "$cancel_lock"
assert_eq "0" "$(find "$OMLX_CANCEL_CACHE" -name '*.task' -type f | wc -l | tr -d ' ')" "cancelled task journal cleared"
pass "oMLX interruption cancels active server work and releases kernel authority"

# 33. A durable active-task journal resumes after launcher death without a
# duplicate POST, and is cleared only after the model becomes visible.
OMLX_RECOVER_BIN="$TMP/omlx-recover-bin"
OMLX_RECOVER_CACHE="$TMP/omlx-recover-cache"
OMLX_RECOVER_VISIBLE="$TMP/omlx-recover-visible"
OMLX_RECOVER_POSTS="$TMP/omlx-recover-posts"
mkdir -p "$OMLX_RECOVER_BIN" "$OMLX_RECOVER_CACHE/omlx-downloads"
printf '0' > "$OMLX_RECOVER_POSTS"
recover_key="$(bash -c 'source "$1"; launcher_profile_key omlx-download-v4 http://omlx model' _ \
  "$ROOT/bin/_launcher-common.sh")"
recover_marker="$OMLX_RECOVER_CACHE/omlx-downloads/${recover_key}.task"
printf '%s\n' '{"version":1,"state":"active","model":"org/model","base":"http://omlx","task_id":"task-recover"}' \
  > "$recover_marker"
make_fake_command "$OMLX_RECOVER_BIN/sync" ':'
make_fake_command "$OMLX_RECOVER_BIN/curl" \
  'url=""; for arg in "$@"; do case "$arg" in http://*|https://*) url="$arg" ;; esac; done' \
  'case "$url" in' \
  '  */v1/models) if [[ -e "$OMLX_RECOVER_VISIBLE" ]]; then printf '\''{"data":[{"id":"model"}]}'\''; else printf '\''{"data":[]}'\''; fi ;;' \
  '  */admin/api/login) printf "200" ;;' \
  '  */admin/api/models) if [[ -e "$OMLX_RECOVER_VISIBLE" ]]; then printf '\''{"models":[{"id":"model","display_name":"org/model","source_repo_id":"org/model"}]}'\''; else printf '\''{"models":[]}'\''; fi ;;' \
  '  */admin/api/hf/tasks) : > "$OMLX_RECOVER_VISIBLE"; printf '\''{"tasks":[{"task_id":"task-recover","repo_id":"org/model","status":"completed","progress":100}]}'\'' ;;' \
  '  */admin/api/hf/download) n="$(cat "$OMLX_RECOVER_POSTS")"; printf "%s" "$((n+1))" > "$OMLX_RECOVER_POSTS"; exit 9 ;;' \
  '  *) exit 2 ;;' \
  'esac'
export OMLX_RECOVER_VISIBLE OMLX_RECOVER_POSTS
FLOX_ENV_CACHE="$OMLX_RECOVER_CACHE" OMLX_MODEL_VISIBLE_POLL_SECONDS=0.1 \
  PATH="$OMLX_RECOVER_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; _omlx_download_model org/model http://omlx key token' _ "$ROOT/bin/_omlx-ensure.sh" \
  >"$TMP/omlx-recover.out" 2>"$TMP/omlx-recover.err"
assert_file_eq "0" "$OMLX_RECOVER_POSTS" "recovered task issued no duplicate POST"
[[ ! -e "$recover_marker" ]] || fail "recovered task journal cleared after visibility"
pass "oMLX active-task journals resume crash-consistently"

# 34. An intent journal without a task ID represents an indeterminate remote
# outcome and must fail closed rather than submit a second download.
OMLX_INTENT_BIN="$TMP/omlx-intent-bin"
OMLX_INTENT_CACHE="$TMP/omlx-intent-cache"
OMLX_INTENT_POSTS="$TMP/omlx-intent-posts"
OMLX_INTENT_VISIBLE="$TMP/omlx-intent-visible"
mkdir -p "$OMLX_INTENT_BIN" "$OMLX_INTENT_CACHE/omlx-downloads"
printf '0' > "$OMLX_INTENT_POSTS"
intent_key="$(bash -c 'source "$1"; launcher_profile_key omlx-download-v4 http://omlx model' _ \
  "$ROOT/bin/_launcher-common.sh")"
intent_marker="$OMLX_INTENT_CACHE/omlx-downloads/${intent_key}.task"
printf '%s\n' '{"version":1,"state":"intent","model":"org/model","base":"http://omlx","task_id":""}' \
  > "$intent_marker"
make_fake_command "$OMLX_INTENT_BIN/sync" ':'
make_fake_command "$OMLX_INTENT_BIN/curl" \
  'url=""; for arg in "$@"; do case "$arg" in http://*|https://*) url="$arg" ;; esac; done' \
  'case "$url" in' \
  '  */v1/models) if [[ -e "$OMLX_INTENT_VISIBLE" ]]; then printf '\''{"data":[{"id":"model"}]}'\''; else printf '\''{"data":[]}'\''; fi ;;' \
  '  */admin/api/login) printf "200" ;;' \
  '  */admin/api/models) if [[ -e "$OMLX_INTENT_VISIBLE" ]]; then printf '\''{"models":[{"id":"model","display_name":"org/model","source_repo_id":"org/model"}]}'\''; else printf '\''{"models":[]}'\''; fi ;;' \
  '  */admin/api/hf/download) n="$(cat "$OMLX_INTENT_POSTS")"; printf "%s" "$((n+1))" > "$OMLX_INTENT_POSTS"; printf '\''{}'\'' ;;' \
  '  *) exit 2 ;;' \
  'esac'
export OMLX_INTENT_POSTS OMLX_INTENT_VISIBLE
set +e
FLOX_ENV_CACHE="$OMLX_INTENT_CACHE" PATH="$OMLX_INTENT_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; _omlx_download_model org/model http://omlx key token' _ "$ROOT/bin/_omlx-ensure.sh" \
  >"$TMP/omlx-intent.out" 2>"$TMP/omlx-intent.err"
status=$?
set -e
assert_eq "1" "$status" "indeterminate oMLX intent fails closed"
assert_file_eq "0" "$OMLX_INTENT_POSTS" "indeterminate intent issued no duplicate POST"
[[ -f "$intent_marker" ]] || fail "indeterminate intent journal retained"
assert_contains "$(cat "$TMP/omlx-intent.err")" "indeterminate outcome" "indeterminate intent diagnostic"
: > "$OMLX_INTENT_VISIBLE"
FLOX_ENV_CACHE="$OMLX_INTENT_CACHE" PATH="$OMLX_INTENT_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; _omlx_download_model org/model http://omlx key token' _ "$ROOT/bin/_omlx-ensure.sh"
[[ ! -e "$intent_marker" ]] || fail "visible model cleared indeterminate task journal"
assert_file_eq "0" "$OMLX_INTENT_POSTS" "visible recovery issued no duplicate POST"
pass "oMLX unknown request outcomes never duplicate downloads"

# 35. A kernel lock is retained after the acquisition helper exits and blocks a
# concurrent owner until the Bash descriptor is closed.
KERNEL_LOCK_DIR="$TMP/kernel-lock-basic"
mkdir -p "$KERNEL_LOCK_DIR"
bash -c '
  set -euo pipefail
  source "$1"
  LAUNCHER_LOCK_FD=""
  launcher_lock_acquire "$2" 2 120 primary
  : > "$3"
  while [[ ! -e "$4" ]]; do sleep 0.02; done
  launcher_lock_release
' _ "$ROOT/bin/_launcher-common.sh" "$KERNEL_LOCK_DIR/test.lock" \
  "$KERNEL_LOCK_DIR/ready" "$KERNEL_LOCK_DIR/release" & kernel_owner=$!
wait_for_process_file "$KERNEL_LOCK_DIR/ready" "$kernel_owner" "kernel owner readiness"
set +e
out="$(bash -c '
  source "$1"
  LAUNCHER_LOCK_FD=""
  launcher_lock_acquire "$2" 0 120 contender
' _ "$ROOT/bin/_launcher-common.sh" "$KERNEL_LOCK_DIR/test.lock" 2>&1)"
status=$?
set -e
assert_eq "1" "$status" "live kernel lock blocks contender"
assert_contains "$out" "timed out waiting" "kernel lock contention diagnostic"
: > "$KERNEL_LOCK_DIR/release"
wait "$kernel_owner"
bash -c '
  source "$1"
  LAUNCHER_LOCK_FD=""
  launcher_lock_acquire "$2" 1 120 contender
  launcher_lock_release
' _ "$ROOT/bin/_launcher-common.sh" "$KERNEL_LOCK_DIR/test.lock"
pass "kernel lock authority survives helper exit and serializes owners"

# 36. SIGKILL of an owner with no protected child closes the descriptor in the
# kernel. There is no heartbeat process and no stale object to reclaim.
HARD_KILL_DIR="$TMP/kernel-lock-hard-kill"
mkdir -p "$HARD_KILL_DIR"
bash -c '
  set -euo pipefail
  source "$1"
  LAUNCHER_LOCK_FD=""
  launcher_lock_acquire "$2" 2 120 hard-kill
  printf "%s\n" "$$" > "$3"
  : > "$4"
  kill -STOP "$$"
' _ "$ROOT/bin/_launcher-common.sh" "$HARD_KILL_DIR/test.lock" \
  "$HARD_KILL_DIR/owner-pid" "$HARD_KILL_DIR/ready" & hard_owner=$!
wait_for_process_file "$HARD_KILL_DIR/ready" "$hard_owner" "hard-kill owner readiness"
owner_pid="$(cat "$HARD_KILL_DIR/owner-pid")"
assert_eq "$hard_owner" "$owner_pid" "hard-kill owner PID"
assert_eq "0" "$(ps -o pid= --ppid "$owner_pid" 2>/dev/null | wc -l | tr -d ' ')" "no heartbeat child exists"
hard_inode_before="$(stat -c %i "$HARD_KILL_DIR/test.lock" 2>/dev/null || stat -f %i "$HARD_KILL_DIR/test.lock")"
kill -KILL "$hard_owner"
set +e
wait "$hard_owner" 2>/dev/null
set -e
bash -c '
  source "$1"
  LAUNCHER_LOCK_FD=""
  launcher_lock_acquire "$2" 2 120 recovery
  launcher_lock_release
' _ "$ROOT/bin/_launcher-common.sh" "$HARD_KILL_DIR/test.lock"
hard_inode_after="$(stat -c %i "$HARD_KILL_DIR/test.lock" 2>/dev/null || stat -f %i "$HARD_KILL_DIR/test.lock")"
assert_eq "$hard_inode_before" "$hard_inode_after" "persistent lock inode survives hard-kill handoff"
pass "hard-killed owners release kernel authority without heartbeats"

# 37. If a protected child survives its Bash owner, its inherited descriptor
# keeps the lock until that operation actually ends. Recovery cannot overlap it.
INHERIT_DIR="$TMP/kernel-lock-inherited-child"
mkdir -p "$INHERIT_DIR"
bash -c '
  set -euo pipefail
  source "$1"
  LAUNCHER_LOCK_FD=""
  launcher_lock_acquire "$2" 2 120 inherited
  sleep 1.2 &
  printf "%s\n" "$!" > "$3"
  : > "$4"
  kill -STOP "$$"
' _ "$ROOT/bin/_launcher-common.sh" "$INHERIT_DIR/test.lock" \
  "$INHERIT_DIR/child-pid" "$INHERIT_DIR/ready" & inherit_owner=$!
wait_for_process_file "$INHERIT_DIR/ready" "$inherit_owner" "inherited-child owner readiness"
inherit_child="$(cat "$INHERIT_DIR/child-pid")"
kill -KILL "$inherit_owner"
set +e
wait "$inherit_owner" 2>/dev/null
out="$(bash -c '
  source "$1"
  LAUNCHER_LOCK_FD=""
  launcher_lock_acquire "$2" 0 120 early-recovery
' _ "$ROOT/bin/_launcher-common.sh" "$INHERIT_DIR/test.lock" 2>&1)"
status=$?
set -e
assert_eq "1" "$status" "surviving protected child retains authority"
assert_contains "$out" "timed out waiting" "inherited authority contention diagnostic"
while kill -0 "$inherit_child" 2>/dev/null; do sleep 0.05; done
bash -c '
  source "$1"
  LAUNCHER_LOCK_FD=""
  launcher_lock_acquire "$2" 2 120 late-recovery
  launcher_lock_release
' _ "$ROOT/bin/_launcher-common.sh" "$INHERIT_DIR/test.lock"
pass "surviving protected children retain authority until completion"

# 38. Multiple contenders arriving after a hard crash serialize through the
# same persistent inode; no two critical sections can be live simultaneously.
MULTI_DIR="$TMP/kernel-lock-multi"
mkdir -p "$MULTI_DIR"
bash -c '
  set -euo pipefail
  source "$1"
  LAUNCHER_LOCK_FD=""
  launcher_lock_acquire "$2" 2 120 doomed
  : > "$3"
  kill -STOP "$$"
' _ "$ROOT/bin/_launcher-common.sh" "$MULTI_DIR/test.lock" "$MULTI_DIR/ready" & doomed_owner=$!
wait_for_process_file "$MULTI_DIR/ready" "$doomed_owner" "post-crash owner readiness"
kill -KILL "$doomed_owner"
set +e
wait "$doomed_owner" 2>/dev/null
set -e
run_contender() {
  bash -c '
    set -euo pipefail
    source "$1"
    LAUNCHER_LOCK_FD=""
    launcher_lock_acquire "$2" 5 120 contender
    if ! mkdir "$3" 2>/dev/null; then : > "$4"; fi
    sleep 0.2
    rmdir "$3"
    launcher_lock_release
  ' _ "$ROOT/bin/_launcher-common.sh" "$MULTI_DIR/test.lock" \
    "$MULTI_DIR/inside" "$MULTI_DIR/overlap"
}
run_contender & multi_a=$!
run_contender & multi_b=$!
wait "$multi_a"; wait "$multi_b"
[[ ! -e "$MULTI_DIR/overlap" ]] || fail "concurrent kernel-lock owners overlapped"
pass "concurrent post-crash contenders preserve mutual exclusion"

# 39. Release never unlinks the lock pathname. Even an rm implementation that
# refuses that path cannot strand authority or change the lock inode.
NO_UNLINK_BIN="$TMP/no-unlink-bin"
NO_UNLINK_DIR="$TMP/no-unlink-lock"
mkdir -p "$NO_UNLINK_BIN" "$NO_UNLINK_DIR"
make_fake_command "$NO_UNLINK_BIN/rm" \
  'for arg in "$@"; do [[ "$arg" != *test.lock ]] || { echo forbidden >&2; exit 99; }; done' \
  'exec /bin/rm "$@"'
PATH="$NO_UNLINK_BIN:/usr/bin:/bin" bash -c '
  set -euo pipefail
  source "$1"
  LAUNCHER_LOCK_FD=""
  launcher_lock_acquire "$2" 2 120 no-unlink
  launcher_lock_release
' _ "$ROOT/bin/_launcher-common.sh" "$NO_UNLINK_DIR/test.lock"
[[ -f "$NO_UNLINK_DIR/test.lock" ]] || fail "persistent lock inode retained"
pass "lock release is descriptor-based and cannot orphan a pathname"

# 40. If ownership state is corrupted and the retained descriptor is already
# gone, release reports failure and preserves its globals for diagnosis.
RELEASE_FAIL_DIR="$TMP/release-failure"
mkdir -p "$RELEASE_FAIL_DIR"
set +e
out="$(bash -c '
  set -euo pipefail
  source "$1"
  LAUNCHER_LOCK_FD=""
  launcher_lock_acquire "$2" 2 120 release-failure
  retained="$LAUNCHER_LOCK_FD"
  eval "exec ${retained}>&-"
  set +e
  launcher_lock_release
  status=$?
  set -e
  printf "status=%s fd=%s file=%s" "$status" "$LAUNCHER_LOCK_FD" "$LAUNCHER_LOCK_FILE"
  exit "$status"
' _ "$ROOT/bin/_launcher-common.sh" "$RELEASE_FAIL_DIR/test.lock" 2>"$RELEASE_FAIL_DIR/err")"
status=$?
set -e
assert_eq "1" "$status" "lost descriptor release fails"
assert_contains "$out" "status=1 fd=" "release failure preserves descriptor identity"
assert_contains "$out" "file=$RELEASE_FAIL_DIR/test.lock" "release failure preserves lock path"
assert_contains "$(cat "$RELEASE_FAIL_DIR/err")" "no longer open" "release failure diagnostic"
pass "lock release failures are explicit and retain ownership state"

# 41. Native acquisition rejects symlink and non-regular lock objects without
# modifying the symlink target.
LOCK_GUARD_DIR="$TMP/lock-target-guard"
mkdir -p "$LOCK_GUARD_DIR/directory-lock"
printf '%s' untouched > "$LOCK_GUARD_DIR/victim"
ln -s "$LOCK_GUARD_DIR/victim" "$LOCK_GUARD_DIR/symlink.lock"
set +e
bash -c 'source "$1"; LAUNCHER_LOCK_FD=""; launcher_lock_acquire "$2" 1 120 symlink' _ \
  "$ROOT/bin/_launcher-common.sh" "$LOCK_GUARD_DIR/symlink.lock" >/dev/null 2>&1
symlink_status=$?
bash -c 'source "$1"; LAUNCHER_LOCK_FD=""; launcher_lock_acquire "$2" 1 120 directory' _ \
  "$ROOT/bin/_launcher-common.sh" "$LOCK_GUARD_DIR/directory-lock" >/dev/null 2>&1
directory_status=$?
set -e
assert_eq "1" "$symlink_status" "symlink lock target rejected"
assert_eq "1" "$directory_status" "directory lock target rejected"
assert_file_eq "untouched" "$LOCK_GUARD_DIR/victim" "symlink lock target not modified"
pass "kernel lock acquisition binds a regular non-symlink inode"

# 42. Profile hashing has no non-cryptographic fallback.
assert_eq "64" "$(bash -c 'source "$1"; key="$(launcher_profile_key a b c)"; printf "%s" "${#key}"' _ "$ROOT/bin/_launcher-common.sh")" "SHA-256 key length"
if grep -q 'cksum' "$ROOT/bin/_launcher-common.sh"; then fail "no cksum fallback"; fi
pass "profile keys require collision-resistant SHA-256"

# 43. A single native lock helper is discoverable and executable.
_lh38="$(_locate_lock_helper)" || fail "no _launcher-lock-helper discoverable"
[[ -x "$_lh38" ]] || fail "discovered helper is not executable: $_lh38"
_lh38_rc=0; "$_lh38" >/dev/null 2>&1 || _lh38_rc=$?
[[ "$_lh38_rc" -eq 64 ]] || fail "helper does not report usage exit 64 (got $_lh38_rc)"
pass "native kernel-lock helper is discoverable and executable"
unset _lh38 _lh38_rc

# 44. A slashless direct Codex launcher receives the key and proven model ID
# exported by omlx_ensure_model.
CODEX_DIRECT="$TMP/codex-direct"
CODEX_BIN="$TMP/codex-bin"
CODEX_CACHE="$TMP/codex-cache"
CODEX_HOME_DIR="$TMP/codex-home"
mkdir -p "$CODEX_DIRECT" "$CODEX_BIN" "$CODEX_CACHE" "$CODEX_HOME_DIR/.omlx"
printf '%s' '{"auth":{"api_key":"resolved-secret"}}' > "$CODEX_HOME_DIR/.omlx/settings.json"
cp "$ROOT/bin/launch-codex-omlx" "$ROOT/bin/_omlx-ensure.sh" \
  "$ROOT/bin/_launcher-common.sh" "$CODEX_DIRECT/"
copy_lock_runtime "$CODEX_DIRECT"
chmod 755 "$CODEX_DIRECT/launch-codex-omlx"
make_fake_command "$CODEX_BIN/curl" \
  'url=""; wants_code=false; for arg in "$@"; do case "$arg" in http://*|https://*) url="$arg" ;; *"%{http_code}"*) wants_code=true ;; esac; done' \
  'case "$url" in' \
  '  */admin/api/login) printf "200" ;;' \
  '  */admin/api/models) printf '\''{"models":[{"id":"Model-4bit","display_name":"org/Model-4bit","source_repo_id":"org/Model-4bit"}]}'\'' ;;' \
  '  */v1/models) if [[ "$wants_code" == true ]]; then printf "200"; else printf '\''{"data":[{"id":"Model-4bit"}]}'\''; fi ;;' \
  '  *) exit 2 ;;' \
  'esac'
make_fake_command "$CODEX_BIN/codex" \
  'printf "key=%s model_id=%s\n" "${OMLX_API_KEY:-unset}" "${OMLX_MODEL_ID:-unset}"' \
  'printf "args="; for arg in "$@"; do printf " <%s>" "$arg"; done; printf "\n"'
codex_out="$(cd "$CODEX_DIRECT" && \
  HOME="$CODEX_HOME_DIR" FLOX_ENV_CACHE="$CODEX_CACHE" PATH="$CODEX_BIN:/usr/bin:/bin" \
  bash launch-codex-omlx --model org/Model-4bit)"
assert_contains "$codex_out" 'key=resolved-secret model_id=Model-4bit' "Codex receives exported oMLX identity"
assert_contains "$codex_out" '<model="Model-4bit">' "Codex selects proven server model ID"
for launcher in "$ROOT"/bin/launch-*; do
  grep -F 'LAUNCHER_SCRIPT_DIR=' "$launcher" >/dev/null || fail "missing robust script directory in ${launcher##*/}"
  ! grep -F '${BASH_SOURCE[0]%/*}/_' "$launcher" >/dev/null || fail "slash-sensitive helper source in ${launcher##*/}"
done
pass "direct launchers resolve helpers slashlessly and export Codex credentials"

# 45. Same-model proxy requests with a changed upstream identity restart once,
# while an identical repeated configuration remains a no-op.
PROXY_ID_BIN="$TMP/proxy-id-bin"
PROXY_ID_CACHE="$TMP/proxy-id-cache"
PROXY_ID_LOG="$TMP/proxy-id.log"
mkdir -p "$PROXY_ID_BIN" "$PROXY_ID_CACHE"
make_fake_command "$PROXY_ID_BIN/sync" ':'
make_fake_command "$PROXY_ID_BIN/curl" 'exit 0'
make_fake_command "$PROXY_ID_BIN/flox" 'printf "%s\n" "$UPSTREAM" >> "$PROXY_ID_LOG"'
export PROXY_ID_LOG
UPSTREAM='http://endpoint-a:11434' FLOX_ENV_CACHE="$PROXY_ID_CACHE" PATH="$PROXY_ID_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; proxy_ensure_model proxy alpha 127.0.0.1:8081 "backend=ollama" "upstream=$UPSTREAM" "protocol=test-v1"' _ \
  "$ROOT/bin/_proxy-ensure.sh"
first_proxy_identity="$(jq -r '.identity' "$PROXY_ID_CACHE/proxy.model.committed")"
UPSTREAM='http://endpoint-b:11434' FLOX_ENV_CACHE="$PROXY_ID_CACHE" PATH="$PROXY_ID_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; proxy_ensure_model proxy alpha 127.0.0.1:8081 "backend=ollama" "upstream=$UPSTREAM" "protocol=test-v1"' _ \
  "$ROOT/bin/_proxy-ensure.sh"
second_proxy_identity="$(jq -r '.identity' "$PROXY_ID_CACHE/proxy.model.committed")"
UPSTREAM='http://endpoint-b:11434' FLOX_ENV_CACHE="$PROXY_ID_CACHE" PATH="$PROXY_ID_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; proxy_ensure_model proxy alpha 127.0.0.1:8081 "backend=ollama" "upstream=$UPSTREAM" "protocol=test-v1"' _ \
  "$ROOT/bin/_proxy-ensure.sh"
assert_eq $'http://endpoint-a:11434\nhttp://endpoint-b:11434' "$(cat "$PROXY_ID_LOG")" "proxy restarts exactly on configuration change"
[[ "$first_proxy_identity" != "$second_proxy_identity" ]] || fail "proxy identity binds upstream endpoint"
pass "proxy committed state binds complete launcher configuration"

# 46. A short public oMLX model ID is never accepted for a different repository,
# and same-short-name repositories serialize through one server namespace lock.
OMLX_PROV_BIN="$TMP/omlx-prov-bin"
OMLX_PROV_CACHE="$TMP/omlx-prov-cache"
OMLX_PROV_HOME="$TMP/omlx-prov-home"
OMLX_PROV_POSTS="$TMP/omlx-prov-posts"
mkdir -p "$OMLX_PROV_BIN" "$OMLX_PROV_CACHE" "$OMLX_PROV_HOME/.omlx"
printf '%s' '{"auth":{"api_key":"prov-key"}}' > "$OMLX_PROV_HOME/.omlx/settings.json"
printf '0' > "$OMLX_PROV_POSTS"
make_fake_command "$OMLX_PROV_BIN/sync" ':'
make_fake_command "$OMLX_PROV_BIN/curl" \
  'url=""; wants_code=false; method="GET"; for arg in "$@"; do case "$arg" in http://*|https://*) url="$arg" ;; *"%{http_code}"*) wants_code=true ;; POST) method="POST" ;; esac; done' \
  'case "$url" in' \
  '  */admin/api/login) printf "200" ;;' \
  '  */admin/api/models) if [[ "${OMLX_PROV_MODE:-single}" == duplicate ]]; then printf '\''{"models":[{"id":"shared-model","display_name":"org-A/shared-model","source_repo_id":"org-A/shared-model"},{"id":"shared-model","display_name":"org-C/shared-model","source_repo_id":"org-C/shared-model"}]}'\''; else printf '\''{"models":[{"id":"shared-model","display_name":"org-A/shared-model","source_repo_id":"org-A/shared-model"}]}'\''; fi ;;' \
  '  */admin/api/hf/download) n="$(cat "$OMLX_PROV_POSTS")"; printf "%s" "$((n+1))" > "$OMLX_PROV_POSTS"; printf '\''{}'\'' ;;' \
  '  */v1/models) if [[ "$wants_code" == true ]]; then printf "200"; else printf '\''{"data":[{"id":"shared-model"}]}'\''; fi ;;' \
  '  *) exit 2 ;;' \
  'esac'
export OMLX_PROV_POSTS
set +e
HOME="$OMLX_PROV_HOME" FLOX_ENV_CACHE="$OMLX_PROV_CACHE" PATH="$OMLX_PROV_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; omlx_ensure_model org-B/shared-model 127.0.0.1 8000' _ "$ROOT/bin/_omlx-ensure.sh" \
  >"$TMP/omlx-prov.out" 2>"$TMP/omlx-prov.err"
status=$?
set -e
assert_eq "1" "$status" "wrong oMLX repository is rejected"
assert_file_eq "0" "$OMLX_PROV_POSTS" "wrong repository triggers no download"
assert_contains "$(cat "$TMP/omlx-prov.err")" "cannot be proven to originate" "wrong-repository provenance diagnostic"
PROV_COOKIE="$TMP/omlx-prov.cookie"
PROV_CURL_ERR="$TMP/omlx-prov-curl.err"
: > "$PROV_COOKIE"
: > "$PROV_CURL_ERR"
set +e
OMLX_PROV_MODE=duplicate PATH="$OMLX_PROV_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; _omlx_prove_repository org-A/shared-model http://127.0.0.1:8000 "$2" "$3" shared-model' _ \
  "$ROOT/bin/_omlx-ensure.sh" "$PROV_COOKIE" "$PROV_CURL_ERR" \
  >"$TMP/omlx-prov-duplicate.out" 2>"$TMP/omlx-prov-duplicate.err"
duplicate_status=$?
set -e
assert_eq "2" "$duplicate_status" "duplicate server model IDs are rejected as ambiguous"
assert_contains "$(cat "$TMP/omlx-prov-duplicate.err")" "multiple records" "duplicate server-ID diagnostic"
prov_lock_a="$(bash -c 'source "$1"; launcher_profile_key omlx-download-v4 http://127.0.0.1:8000 shared-model' _ "$ROOT/bin/_launcher-common.sh")"
prov_lock_b="$(bash -c 'source "$1"; launcher_profile_key omlx-download-v4 http://127.0.0.1:8000 shared-model' _ "$ROOT/bin/_launcher-common.sh")"
assert_eq "$prov_lock_a" "$prov_lock_b" "same short-name repositories share download authority"
pass "oMLX model acceptance is repository-provenance aware"

# 47. A FIFO lock object cannot block the shell before native validation.
FIFO_DIR="$TMP/fifo-lock"
mkdir -p "$FIFO_DIR"
mkfifo "$FIFO_DIR/test.lock"
set +e
timeout 2 bash -c 'source "$1"; LAUNCHER_LOCK_FD=""; launcher_lock_acquire "$2" 0 120 fifo' _ \
  "$ROOT/bin/_launcher-common.sh" "$FIFO_DIR/test.lock" >"$TMP/fifo.out" 2>"$TMP/fifo.err"
status=$?
set -e
[[ "$status" -ne 124 ]] || fail "FIFO lock open blocked before native validation"
assert_eq "1" "$status" "FIFO lock is rejected"
assert_contains "$(cat "$TMP/fifo.err")" "refusing non-regular" "FIFO rejection diagnostic"
pass "lock opening cannot hang on a FIFO pathname"

# 48. Task identity is bound to both task ID and exact repository.
OMLX_TASK_BIN="$TMP/omlx-task-id-bin"
OMLX_TASK_ERR="$TMP/omlx-task-id.err"
mkdir -p "$OMLX_TASK_BIN"
make_fake_command "$OMLX_TASK_BIN/curl" \
  'printf '\''{"tasks":[{"task_id":"same-task","repo_id":"org-A/shared","status":"completed"}]}'\'''
: > "$OMLX_TASK_ERR"
set +e
PATH="$OMLX_TASK_BIN:/usr/bin:/bin" bash -c 'source "$1"; _omlx_fetch_task_snapshot http://omlx cookies same-task org-B/shared "$2"' _ \
  "$ROOT/bin/_omlx-ensure.sh" "$OMLX_TASK_ERR"
status=$?
set -e
assert_eq "3" "$status" "wrong-repository task identity is malformed"
pass "oMLX task recovery binds the exact repository"

# 49-54. Proxy schema-v2 records are self-consistent and complete-tuple bound.
PROXY_AUTH_BIN="$TMP/proxy-auth-bin"
mkdir -p "$PROXY_AUTH_BIN"
make_fake_command "$PROXY_AUTH_BIN/sync" ':'
make_fake_command "$PROXY_AUTH_BIN/curl" 'exit 0'
make_fake_command "$PROXY_AUTH_BIN/flox" 'printf "restart\n" >> "$PROXY_AUTH_LOG"'
proxy_auth_runtime="$(bash -c 'source "$1"; launcher_profile_key proxy-runtime-v2 proxy http://127.0.0.1:8081 backend=test' _ "$ROOT/bin/_launcher-common.sh")"
proxy_auth_identity="$(bash -c 'source "$1"; launcher_profile_key proxy-applied-v2 proxy alpha "$2"' _ "$ROOT/bin/_launcher-common.sh" "$proxy_auth_runtime")"
proxy_other_runtime="$(bash -c 'source "$1"; launcher_profile_key proxy-runtime-v2 other-service http://127.0.0.1:8081 backend=test' _ "$ROOT/bin/_launcher-common.sh")"
proxy_other_identity="$(bash -c 'source "$1"; launcher_profile_key proxy-applied-v2 other-service alpha "$2"' _ "$ROOT/bin/_launcher-common.sh" "$proxy_other_runtime")"

# 49. A committed record cannot pair a requested-model digest with another model.
PROXY_AUTH_CACHE="$TMP/proxy-auth-committed-model"
PROXY_AUTH_LOG="$TMP/proxy-auth-committed-model.log"
mkdir -p "$PROXY_AUTH_CACHE"
: > "$PROXY_AUTH_LOG"
printf '%s' alpha > "$PROXY_AUTH_CACHE/proxy.model"
jq -cn --arg runtime "$proxy_auth_runtime" --arg identity "$proxy_auth_identity" \
  '{version:2,service:"proxy",model:"beta",listen:"http://127.0.0.1:8081",runtime_id:$runtime,identity:$identity}' \
  > "$PROXY_AUTH_CACHE/proxy.model.committed"
set +e
FLOX_ENV_CACHE="$PROXY_AUTH_CACHE" PROXY_AUTH_LOG="$PROXY_AUTH_LOG" PATH="$PROXY_AUTH_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; proxy_ensure_model proxy alpha 127.0.0.1:8081 backend=test' _ \
  "$ROOT/bin/_proxy-ensure.sh" >"$TMP/proxy-auth-committed-model.out" 2>"$TMP/proxy-auth-committed-model.err"
status=$?
set -e
assert_eq "1" "$status" "committed model/digest mismatch fails closed"
assert_contains "$(cat "$TMP/proxy-auth-committed-model.err")" "internally inconsistent committed proxy state" "committed model mismatch diagnostic"
[[ ! -s "$PROXY_AUTH_LOG" ]] || fail "corrupt committed model did not restart"
pass "proxy committed model is authenticated by its applied identity"

# 50. A committed record cannot pair another service with this service's digest.
PROXY_AUTH_CACHE="$TMP/proxy-auth-committed-service"
PROXY_AUTH_LOG="$TMP/proxy-auth-committed-service.log"
mkdir -p "$PROXY_AUTH_CACHE"
: > "$PROXY_AUTH_LOG"
printf '%s' alpha > "$PROXY_AUTH_CACHE/proxy.model"
jq -cn --arg runtime "$proxy_auth_runtime" --arg identity "$proxy_auth_identity" \
  '{version:2,service:"other-service",model:"alpha",listen:"http://127.0.0.1:8081",runtime_id:$runtime,identity:$identity}' \
  > "$PROXY_AUTH_CACHE/proxy.model.committed"
set +e
FLOX_ENV_CACHE="$PROXY_AUTH_CACHE" PROXY_AUTH_LOG="$PROXY_AUTH_LOG" PATH="$PROXY_AUTH_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; proxy_ensure_model proxy alpha 127.0.0.1:8081 backend=test' _ \
  "$ROOT/bin/_proxy-ensure.sh" >"$TMP/proxy-auth-committed-service.out" 2>"$TMP/proxy-auth-committed-service.err"
status=$?
set -e
assert_eq "1" "$status" "committed service/digest mismatch fails closed"
assert_contains "$(cat "$TMP/proxy-auth-committed-service.err")" "internally inconsistent committed proxy state" "committed service mismatch diagnostic"
[[ ! -s "$PROXY_AUTH_LOG" ]] || fail "corrupt committed service did not restart"
# Even a self-consistent record for another service is invalid at this service-keyed path.
jq -cn --arg runtime "$proxy_other_runtime" --arg identity "$proxy_other_identity" \
  '{version:2,service:"other-service",model:"alpha",listen:"http://127.0.0.1:8081",runtime_id:$runtime,identity:$identity}' \
  > "$PROXY_AUTH_CACHE/proxy.model.committed"
set +e
FLOX_ENV_CACHE="$PROXY_AUTH_CACHE" PROXY_AUTH_LOG="$PROXY_AUTH_LOG" PATH="$PROXY_AUTH_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; proxy_ensure_model proxy alpha 127.0.0.1:8081 backend=test' _ \
  "$ROOT/bin/_proxy-ensure.sh" >"$TMP/proxy-auth-other-service.out" 2>"$TMP/proxy-auth-other-service.err"
status=$?
set -e
assert_eq "1" "$status" "foreign-service committed record fails closed"
assert_contains "$(cat "$TMP/proxy-auth-other-service.err")" "belongs to service other-service" "foreign-service path binding diagnostic"
[[ ! -s "$PROXY_AUTH_LOG" ]] || fail "foreign-service committed record did not restart"
pass "proxy committed service is authenticated and path-bound"

# 51. A malformed transition target identity is rejected before recovery.
PROXY_AUTH_CACHE="$TMP/proxy-auth-transition-target"
PROXY_AUTH_LOG="$TMP/proxy-auth-transition-target.log"
mkdir -p "$PROXY_AUTH_CACHE"
: > "$PROXY_AUTH_LOG"
printf '%s' alpha > "$PROXY_AUTH_CACHE/proxy.model"
jq -cn --arg runtime "$proxy_auth_runtime" --arg identity "$proxy_auth_identity" \
  '{version:2,target:{version:2,service:"proxy",model:"beta",listen:"http://127.0.0.1:8081",runtime_id:$runtime,identity:$identity},previous_present:false,previous:null}' \
  > "$PROXY_AUTH_CACHE/proxy.model.transition"
set +e
FLOX_ENV_CACHE="$PROXY_AUTH_CACHE" PROXY_AUTH_LOG="$PROXY_AUTH_LOG" PATH="$PROXY_AUTH_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; proxy_ensure_model proxy alpha 127.0.0.1:8081 backend=test' _ \
  "$ROOT/bin/_proxy-ensure.sh" >"$TMP/proxy-auth-transition-target.out" 2>"$TMP/proxy-auth-transition-target.err"
status=$?
set -e
assert_eq "1" "$status" "transition target identity mismatch fails closed"
assert_contains "$(cat "$TMP/proxy-auth-transition-target.err")" "internally inconsistent transition target proxy state" "transition target mismatch diagnostic"
[[ ! -s "$PROXY_AUTH_LOG" ]] || fail "corrupt transition target did not restart"
pass "proxy transition target records authenticate their contents"

# 52. A malformed transition previous identity is also rejected.
PROXY_AUTH_CACHE="$TMP/proxy-auth-transition-previous"
PROXY_AUTH_LOG="$TMP/proxy-auth-transition-previous.log"
mkdir -p "$PROXY_AUTH_CACHE"
: > "$PROXY_AUTH_LOG"
printf '%s' alpha > "$PROXY_AUTH_CACHE/proxy.model"
jq -cn \
  --arg runtime "$proxy_auth_runtime" \
  --arg alpha_identity "$proxy_auth_identity" \
  '{version:2,target:{version:2,service:"proxy",model:"alpha",listen:"http://127.0.0.1:8081",runtime_id:$runtime,identity:$alpha_identity},previous_present:true,previous:{version:2,service:"proxy",model:"beta",listen:"http://127.0.0.1:8081",runtime_id:$runtime,identity:$alpha_identity}}' \
  > "$PROXY_AUTH_CACHE/proxy.model.transition"
set +e
FLOX_ENV_CACHE="$PROXY_AUTH_CACHE" PROXY_AUTH_LOG="$PROXY_AUTH_LOG" PATH="$PROXY_AUTH_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; proxy_ensure_model proxy alpha 127.0.0.1:8081 backend=test' _ \
  "$ROOT/bin/_proxy-ensure.sh" >"$TMP/proxy-auth-transition-previous.out" 2>"$TMP/proxy-auth-transition-previous.err"
status=$?
set -e
assert_eq "1" "$status" "transition previous identity mismatch fails closed"
assert_contains "$(cat "$TMP/proxy-auth-transition-previous.err")" "internally inconsistent transition previous proxy state" "transition previous mismatch diagnostic"
[[ ! -s "$PROXY_AUTH_LOG" ]] || fail "corrupt transition previous did not restart"
pass "proxy transition previous records authenticate their contents"

# 53. Even a digest-consistent committed record must match every request field.
# The v2 applied digest intentionally authenticates service/model/runtime_id; the
# listener is therefore compared explicitly as part of the complete tuple.
PROXY_AUTH_CACHE="$TMP/proxy-auth-committed-listen"
PROXY_AUTH_LOG="$TMP/proxy-auth-committed-listen.log"
mkdir -p "$PROXY_AUTH_CACHE"
: > "$PROXY_AUTH_LOG"
printf '%s' alpha > "$PROXY_AUTH_CACHE/proxy.model"
jq -cn --arg runtime "$proxy_auth_runtime" --arg identity "$proxy_auth_identity" \
  '{version:2,service:"proxy",model:"alpha",listen:"http://other-listener:8081",runtime_id:$runtime,identity:$identity}' \
  > "$PROXY_AUTH_CACHE/proxy.model.committed"
FLOX_ENV_CACHE="$PROXY_AUTH_CACHE" PROXY_AUTH_LOG="$PROXY_AUTH_LOG" PATH="$PROXY_AUTH_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; proxy_ensure_model proxy alpha 127.0.0.1:8081 backend=test' _ \
  "$ROOT/bin/_proxy-ensure.sh"
assert_file_eq "restart" "$PROXY_AUTH_LOG" "listener-mismatched commit forces restart"
assert_eq "http://127.0.0.1:8081" "$(jq -r '.listen' "$PROXY_AUTH_CACHE/proxy.model.committed")" "restart replaces mismatched committed listener"
pass "proxy fast path compares the complete committed tuple"

# 54. Transition recovery likewise rejects an identity-equal but listener-different side.
PROXY_AUTH_CACHE="$TMP/proxy-auth-transition-listen"
PROXY_AUTH_LOG="$TMP/proxy-auth-transition-listen.log"
mkdir -p "$PROXY_AUTH_CACHE"
: > "$PROXY_AUTH_LOG"
printf '%s' alpha > "$PROXY_AUTH_CACHE/proxy.model"
jq -cn --arg runtime "$proxy_auth_runtime" --arg identity "$proxy_auth_identity" \
  '{version:2,target:{version:2,service:"proxy",model:"alpha",listen:"http://other-listener:8081",runtime_id:$runtime,identity:$identity},previous_present:false,previous:null}' \
  > "$PROXY_AUTH_CACHE/proxy.model.transition"
set +e
FLOX_ENV_CACHE="$PROXY_AUTH_CACHE" PROXY_AUTH_LOG="$PROXY_AUTH_LOG" PATH="$PROXY_AUTH_BIN:/usr/bin:/bin" \
  bash -c 'source "$1"; proxy_ensure_model proxy alpha 127.0.0.1:8081 backend=test' _ \
  "$ROOT/bin/_proxy-ensure.sh" >"$TMP/proxy-auth-transition-listen.out" 2>"$TMP/proxy-auth-transition-listen.err"
status=$?
set -e
assert_eq "1" "$status" "transition listener mismatch fails closed"
assert_contains "$(cat "$TMP/proxy-auth-transition-listen.err")" "matches neither side" "transition complete-tuple mismatch diagnostic"
[[ ! -s "$PROXY_AUTH_LOG" ]] || fail "listener-mismatched transition did not restart"
pass "proxy transition recovery compares complete record tuples"

# 55. Every shipped shell file parses.
shopt -s nullglob
for file in "$ROOT"/bin/*.sh "$ROOT"/bin/launch "$ROOT"/bin/launch-* \
    "$ROOT"/tests/*.sh; do
  bash -n "$file"
done
shopt -u nullglob
pass "all shell files pass bash -n"

printf '1..%d\n' "$PASS"
[[ $FAIL -eq 0 ]]
