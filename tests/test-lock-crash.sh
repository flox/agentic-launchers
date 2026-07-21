#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
TMP="$(mktemp -d -t launcher-lock-crash.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
PASS=0

pass() {
  PASS=$((PASS + 1))
  printf 'ok %d - %s\n' "$PASS" "$1"
}

fail() {
  echo "not ok - $1" >&2
  exit 1
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

wait_file() {
  local file="$1" attempts="${2:-200}"
  while [[ ! -e "$file" && "$attempts" -gt 0 ]]; do
    sleep 0.02
    attempts=$((attempts - 1))
  done
  [[ -e "$file" ]] || fail "timed out waiting for $file"
}

function_owner_pid() {
  local wrapper_pid="$1" child="" attempts=200
  while [[ "$attempts" -gt 0 ]]; do
    child="$(ps -o pid= --ppid "$wrapper_pid" 2>/dev/null | awk 'NR == 1 { print $1 }')"
    if [[ -n "$child" ]]; then
      printf '%s' "$child"
      return 0
    fi
    sleep 0.02
    attempts=$((attempts - 1))
  done
  return 1
}

lock_attempt() {
  local lock_file="$1" wait_seconds="$2"
  bash -c '
    set -euo pipefail
    source "$1"
    LAUNCHER_LOCK_FD=""
    launcher_lock_acquire "$2" "$3" 120 qualification
    launcher_lock_release
  ' _ "$ROOT/bin/_launcher-common.sh" "$lock_file" "$wait_seconds" >/dev/null 2>&1
}

wait_lock_busy() {
  local lock_file="$1" attempts=200
  while [[ "$attempts" -gt 0 ]]; do
    if ! lock_attempt "$lock_file" 0; then
      return 0
    fi
    sleep 0.02
    attempts=$((attempts - 1))
  done
  fail "lock never became busy: $lock_file"
}

wait_lock_free() {
  local lock_file="$1" attempts=300
  while [[ "$attempts" -gt 0 ]]; do
    if lock_attempt "$lock_file" 0; then
      return 0
    fi
    sleep 0.02
    attempts=$((attempts - 1))
  done
  fail "lock never became free: $lock_file"
}

kill_function_owner() {
  local wrapper_pid="$1" owner_pid=""
  owner_pid="$(function_owner_pid "$wrapper_pid")" || fail "could not identify function subshell for $wrapper_pid"
  kill -KILL "$owner_pid"
  set +e
  wait "$wrapper_pid" 2>/dev/null
  set -e
}

crash_publication() {
  local function_name="$1" target="$2" label="$3"
  local dir="${target%/*}"
  local fifo="$dir/input.fifo" writer_ready="$dir/writer-ready"
  local release_writer="$dir/release-writer" lock_file="${target}.write.lock"
  local writer_pid="" wrapper_pid=""

  mkdir -p "$dir"
  mkfifo "$fifo"
  (
    exec 3>"$fifo"
    : > "$writer_ready"
    while [[ ! -e "$release_writer" ]]; do sleep 0.02; done
    exec 3>&-
  ) & writer_pid=$!

  bash -c '
    set -euo pipefail
    source "$1"
    "$2" "$3" 600 < "$4"
  ' _ "$ROOT/bin/_launcher-common.sh" "$function_name" "$target" "$fifo" \
    >"$dir/owner.out" 2>"$dir/owner.err" & wrapper_pid=$!

  wait_file "$writer_ready"
  wait_lock_busy "$lock_file"
  kill_function_owner "$wrapper_pid"
  wait_lock_busy "$lock_file"
  : > "$release_writer"
  wait "$writer_pid"
  wait_lock_free "$lock_file"

  printf '%s' recovered | bash -c '
    set -euo pipefail
    source "$1"
    "$2" "$3" 600
  ' _ "$ROOT/bin/_launcher-common.sh" "$function_name" "$target"
  [[ "$(cat "$target")" == "recovered" ]] || fail "$label recovery publication"
  pass "$label hard-kill preserves authority until its writer exits"
}

# 1-2. Both publication primitives retain authority in their orphaned cat child.
crash_publication launcher_atomic_write_file "$TMP/config/config.json" "atomic config publication"
crash_publication launcher_write_file_if_absent "$TMP/credential/token" "no-clobber credential publication"

# 3. Ollama pull: the blocked HTTP child inherits the per-model lock. A hard-kill
# cannot permit a duplicate pull while that request is still in flight.
OLLAMA_BIN="$TMP/ollama-bin"
OLLAMA_CACHE="$TMP/ollama-cache"
OLLAMA_STATE="$TMP/ollama-state"
mkdir -p "$OLLAMA_BIN" "$OLLAMA_CACHE" "$OLLAMA_STATE"
make_fake_command "$OLLAMA_BIN/sync" ':'
make_fake_command "$OLLAMA_BIN/curl" \
  'url=""; for arg in "$@"; do case "$arg" in http://*|https://*) url="$arg" ;; esac; done' \
  'case "$url" in' \
  '  */api/tags) if [[ -e "$OLLAMA_STATE/visible" ]]; then printf '\''{"models":[{"name":"alpha:latest"}]}'\''; else printf '\''{"models":[]}'\''; fi ;;' \
  '  */api/pull) : > "$OLLAMA_STATE/pull-started"; while [[ ! -e "$OLLAMA_STATE/allow-pull" ]]; do sleep 0.02; done; : > "$OLLAMA_STATE/visible"; printf '\''{"status":"success"}'\'' ;;' \
  '  *) exit 2 ;;' \
  'esac'
export OLLAMA_STATE
ollama_key="$(bash -c 'source "$1"; launcher_profile_key ollama-pull-v2 http://ollama alpha:latest' _ "$ROOT/bin/_launcher-common.sh")"
ollama_lock="$OLLAMA_CACHE/ollama-pulls/${ollama_key}.lock"
ollama_marker="$OLLAMA_CACHE/ollama-pulls/${ollama_key}.intent"
FLOX_ENV_CACHE="$OLLAMA_CACHE" PATH="$OLLAMA_BIN:/usr/bin:/bin" \
  bash -c 'set -euo pipefail; source "$1"; ollama_ensure_model alpha http://ollama' _ \
  "$ROOT/bin/_ollama-ensure.sh" >"$TMP/ollama-owner.out" 2>"$TMP/ollama-owner.err" & ollama_wrapper=$!
wait_file "$OLLAMA_STATE/pull-started"
wait_file "$ollama_marker"
wait_lock_busy "$ollama_lock"
kill_function_owner "$ollama_wrapper"
wait_lock_busy "$ollama_lock"
: > "$OLLAMA_STATE/allow-pull"
wait_lock_free "$ollama_lock"
FLOX_ENV_CACHE="$OLLAMA_CACHE" PATH="$OLLAMA_BIN:/usr/bin:/bin" \
  bash -c 'set -euo pipefail; source "$1"; ollama_ensure_model alpha http://ollama' _ \
  "$ROOT/bin/_ollama-ensure.sh"
[[ ! -e "$ollama_marker" ]] || fail "Ollama recovery cleared durable intent"
pass "Ollama pull hard-kill cannot overlap its surviving request"

# 4. oMLX download: kill the function while task polling is blocked. The polling
# child retains the endpoint/model lock; recovery resumes the durable task later.
OMLX_BIN="$TMP/omlx-bin"
OMLX_CACHE="$TMP/omlx-cache"
OMLX_STATE="$TMP/omlx-state"
mkdir -p "$OMLX_BIN" "$OMLX_CACHE" "$OMLX_STATE"
make_fake_command "$OMLX_BIN/sync" ':'
make_fake_command "$OMLX_BIN/curl" \
  'url=""; for arg in "$@"; do case "$arg" in http://*|https://*) url="$arg" ;; esac; done' \
  'case "$url" in' \
  '  */v1/models) if [[ -e "$OMLX_STATE/visible" ]]; then printf '\''{"data":[{"id":"model"}]}'\''; else printf '\''{"data":[]}'\''; fi ;;' \
  '  */admin/api/login) printf "200" ;;' \
  '  */admin/api/models) if [[ -e "$OMLX_STATE/visible" ]]; then printf '\''{"models":[{"id":"model","display_name":"org/model","source_repo_id":"org/model"}]}'\''; else printf '\''{"models":[]}'\''; fi ;;' \
  '  */admin/api/hf/download) printf '\''{"success":true,"task":{"task_id":"task-crash","repo_id":"org/model"}}'\'' ;;' \
  '  */admin/api/hf/tasks) : > "$OMLX_STATE/task-poll-started"; while [[ ! -e "$OMLX_STATE/allow-task" ]]; do sleep 0.02; done; : > "$OMLX_STATE/visible"; printf '\''{"tasks":[{"task_id":"task-crash","repo_id":"org/model","status":"completed","progress":100}]}'\'' ;;' \
  '  */admin/api/hf/cancel/*) printf '\''{"success":true}'\'' ;;' \
  '  *) exit 2 ;;' \
  'esac'
export OMLX_STATE
omlx_key="$(bash -c 'source "$1"; launcher_profile_key omlx-download-v4 http://omlx model' _ "$ROOT/bin/_launcher-common.sh")"
omlx_lock="$OMLX_CACHE/omlx-downloads/${omlx_key}.lock"
omlx_marker="$OMLX_CACHE/omlx-downloads/${omlx_key}.task"
FLOX_ENV_CACHE="$OMLX_CACHE" OMLX_DOWNLOAD_POLL_SECONDS=0.1 OMLX_MODEL_VISIBLE_POLL_SECONDS=0.1 \
  PATH="$OMLX_BIN:/usr/bin:/bin" \
  bash -c 'set -euo pipefail; source "$1"; _omlx_download_model org/model http://omlx key token' _ \
  "$ROOT/bin/_omlx-ensure.sh" >"$TMP/omlx-owner.out" 2>"$TMP/omlx-owner.err" & omlx_wrapper=$!
wait_file "$OMLX_STATE/task-poll-started"
wait_file "$omlx_marker"
wait_lock_busy "$omlx_lock"
kill_function_owner "$omlx_wrapper"
wait_lock_busy "$omlx_lock"
: > "$OMLX_STATE/allow-task"
wait_lock_free "$omlx_lock"
FLOX_ENV_CACHE="$OMLX_CACHE" OMLX_DOWNLOAD_POLL_SECONDS=0.1 OMLX_MODEL_VISIBLE_POLL_SECONDS=0.1 \
  PATH="$OMLX_BIN:/usr/bin:/bin" \
  bash -c 'set -euo pipefail; source "$1"; _omlx_download_model org/model http://omlx key token' _ \
  "$ROOT/bin/_omlx-ensure.sh"
[[ ! -e "$omlx_marker" ]] || fail "oMLX recovery cleared durable task journal"
pass "oMLX download hard-kill cannot overlap its surviving task poll"

# 5. Proxy transition: the bounded restart worker and its flox child inherit the
# service lock. A killed transition owner cannot overlap a still-running restart.
PROXY_BIN="$TMP/proxy-bin"
PROXY_CACHE="$TMP/proxy-cache"
PROXY_STATE="$TMP/proxy-state"
mkdir -p "$PROXY_BIN" "$PROXY_CACHE" "$PROXY_STATE"
make_fake_command "$PROXY_BIN/sync" ':'
make_fake_command "$PROXY_BIN/curl" 'exit 0'
make_fake_command "$PROXY_BIN/flox" \
  '[[ "$*" == "services restart proxy-service" ]] || exit 2' \
  ': > "$PROXY_STATE/restart-started"' \
  'while [[ ! -e "$PROXY_STATE/allow-restart" ]]; do sleep 0.02; done'
export PROXY_STATE
proxy_lock="$PROXY_CACHE/proxy-service.model.lock"
FLOX_ENV_CACHE="$PROXY_CACHE" PROXY_RESTART_TIMEOUT_SECONDS=10 PROXY_READY_TIMEOUT_SECONDS=2 \
  PATH="$PROXY_BIN:/usr/bin:/bin" \
  bash -c 'set -euo pipefail; source "$1"; proxy_ensure_model proxy-service alpha 127.0.0.1:9999 "backend=test"' _ \
  "$ROOT/bin/_proxy-ensure.sh" >"$TMP/proxy-owner.out" 2>"$TMP/proxy-owner.err" & proxy_wrapper=$!
wait_file "$PROXY_STATE/restart-started"
wait_lock_busy "$proxy_lock"
kill_function_owner "$proxy_wrapper"
wait_lock_busy "$proxy_lock"
: > "$PROXY_STATE/allow-restart"
wait_lock_free "$proxy_lock"
FLOX_ENV_CACHE="$PROXY_CACHE" PROXY_RESTART_TIMEOUT_SECONDS=10 PROXY_READY_TIMEOUT_SECONDS=2 \
  PATH="$PROXY_BIN:/usr/bin:/bin" \
  bash -c 'set -euo pipefail; source "$1"; proxy_ensure_model proxy-service alpha 127.0.0.1:9999 "backend=test"' _ \
  "$ROOT/bin/_proxy-ensure.sh"
[[ ! -e "$PROXY_CACHE/proxy-service.model.transition" ]] || fail "proxy recovery cleared transition marker"
pass "proxy transition hard-kill cannot overlap its surviving restart"

printf '1..%d\n' "$PASS"
