# Shared helper — sourced by launch-* omlx wrappers.
# Ensures a model becomes discoverable through oMLX's /v1/models API,
# downloading it from HuggingFace when absent. Exports OMLX_API_KEY and the
# provenance-verified server-visible OMLX_MODEL_ID on success.

case "${BASH_SOURCE[0]}" in
  */*) _OMLX_HELPER_DIR="${BASH_SOURCE[0]%/*}" ;;
  *) _OMLX_HELPER_DIR="." ;;
esac
_OMLX_HELPER_DIR="$(cd -- "$_OMLX_HELPER_DIR" && pwd -P)" || return 1
source "$_OMLX_HELPER_DIR/_launcher-common.sh"
unset _OMLX_HELPER_DIR

_omlx_validate_scalar() {
  local value="$1" label="$2"
  if [[ -z "$value" || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "Error: invalid $label value" >&2
    return 1
  fi
}

_omlx_base_url() {
  local host="$1" port="$2"
  _omlx_validate_scalar "$host" "oMLX host" || return 1
  case "$port" in ''|*[!0-9]*) echo "Error: invalid oMLX port: $port" >&2; return 1 ;; esac
  [[ "$port" -ge 1 && "$port" -le 65535 ]] || {
    echo "Error: invalid oMLX port: $port" >&2
    return 1
  }
  case "$host" in
    http://*|https://*)
      echo "Error: OMLX_HOST must not include a URL scheme" >&2
      return 1
      ;;
    *:*)
      case "$host" in \[*\]) ;; *) host="[$host]" ;; esac
      ;;
  esac
  printf 'http://%s:%s' "$host" "$port"
}

# --- HF token helpers ---

_hf_token_from_keychain() {
  [[ "$(uname)" == "Darwin" ]] || return 1
  security find-generic-password -s "huggingface-token" -a "default" -w 2>/dev/null
}

_hf_token_save_keychain() {
  local token="$1"
  [[ "$(uname)" == "Darwin" ]] || return 1
  security add-generic-password -s "huggingface-token" -a "default" -U -w "$token" 2>/dev/null
}

_hf_token_write_file() {
  local token="$1" token_dir="$HOME/.cache/huggingface" token_file
  token_file="$token_dir/token"
  mkdir -p "$token_dir" || return 1
  printf '%s' "$token" | launcher_atomic_write_file "$token_file" 600 true
}

# Resolves a HuggingFace token via (in order):
#   1. macOS keychain
#   2. ~/.cache/huggingface/token (HF CLI standard location)
#   3. Interactive gum/read prompt; saves the result for future runs
_hf_token_get() {
  local model="${1:-model}" token="" token_file="$HOME/.cache/huggingface/token"

  token="$(_hf_token_from_keychain)" || true

  if [[ -z "$token" && ( -e "$token_file" || -L "$token_file" ) ]]; then
    if [[ -L "$token_file" || ! -f "$token_file" ]]; then
      echo "Error: refusing invalid HuggingFace token cache: $token_file" >&2
      return 1
    fi
    token="$(cat "$token_file")" || return 1
  fi

  if [[ -z "$token" ]]; then
    if [[ ! -t 2 ]]; then
      echo "Error: HuggingFace token required to download '${model}'." >&2
      echo "  Run this command in an interactive terminal, or populate ~/.cache/huggingface/token" >&2
      return 1
    fi
    if command -v gum >/dev/null 2>&1; then
      token="$(gum input --password \
        --header "HuggingFace token required to download '${model}'." \
        --placeholder "hf_..." \
        --char-limit 0)" || { echo "Aborted." >&2; return 1; }
    else
      read -rsp "HuggingFace token: " token </dev/tty
      echo >&2
    fi
    if [[ -z "$token" ]]; then
      echo "Error: no token provided." >&2
      return 1
    fi
    if _hf_token_save_keychain "$token"; then
      echo "  Token saved to macOS keychain." >&2
    fi
    if ! _hf_token_write_file "$token"; then
      echo "Error: could not save HuggingFace token cache" >&2
      return 1
    fi
  fi

  printf '%s' "$token"
}

# --- oMLX API key helpers ---

_omlx_key_from_keychain() {
  [[ "$(uname)" == "Darwin" ]] || return 1
  security find-generic-password -s "omlx-api-key" -a "default" -w 2>/dev/null
}

_omlx_key_save_keychain() {
  local key="$1"
  [[ "$(uname)" == "Darwin" ]] || return 1
  security add-generic-password -s "omlx-api-key" -a "default" -U -w "$key" 2>/dev/null
}

_omlx_key_verify() {
  local key="$1" base="$2"
  curl -sfS --connect-timeout 3 --max-time 5 \
    -H "Authorization: Bearer $key" \
    "$base/v1/models" >/dev/null 2>&1
}

# Resolve the key that authenticates against this exact endpoint.
_omlx_key_get() {
  local base="$1" endpoint_label="$2"
  local key="" candidate="" settings="$HOME/.omlx/settings.json" cache_key=""

  key="$(_omlx_key_from_keychain)" || true
  if [[ -n "$key" ]] && _omlx_key_verify "$key" "$base"; then
    printf '%s' "$key"
    return 0
  fi

  if [[ -e "$settings" || -L "$settings" ]]; then
    if [[ -L "$settings" || ! -f "$settings" ]]; then
      echo "Error: refusing invalid oMLX settings object: $settings" >&2
      return 1
    fi
    candidate="$(jq -r '.auth.api_key // empty' "$settings" 2>/dev/null || true)"
    if [[ -n "$candidate" ]] && _omlx_key_verify "$candidate" "$base"; then
      _omlx_key_save_keychain "$candidate" || true
      printf '%s' "$candidate"
      return 0
    fi
  fi

  cache_key="${FLOX_ENV_CACHE:-}/omlx.api-key"
  if [[ -n "${FLOX_ENV_CACHE:-}" && ( -e "$cache_key" || -L "$cache_key" ) ]]; then
    if [[ -L "$cache_key" || ! -f "$cache_key" ]]; then
      echo "Error: refusing invalid cached oMLX API key: $cache_key" >&2
      return 1
    fi
    candidate="$(cat "$cache_key")" || return 1
    if [[ -n "$candidate" ]] && _omlx_key_verify "$candidate" "$base"; then
      _omlx_key_save_keychain "$candidate" || true
      printf '%s' "$candidate"
      return 0
    fi
  fi

  echo "Error: could not find a valid oMLX API key for $endpoint_label" >&2
  echo "  Is oMLX running? Try: flox services status  (start with: flox activate -s)" >&2
  return 1
}

# Return 0=unambiguously present for a slashless local ID, 1=absent,
# 2=unreachable, 3=malformed/ambiguous response, 4=visible but a full
# repository request still requires admin provenance verification.
# OMLX_VISIBLE_MODEL_ID is populated on 0 or 4.
_omlx_model_is_loaded() {
  local model="$1" base="$2" api_key="$3" models="" short_name=""
  local exact_count="" short_count="" selected=""
  OMLX_VISIBLE_MODEL_ID=""

  if ! models="$(curl -fsS --connect-timeout 5 --max-time 10 \
      -H "Authorization: Bearer $api_key" \
      "$base/v1/models" 2>/dev/null)"; then
    return 2
  fi
  if ! printf '%s' "$models" | jq -e '(.data | type) == "array"' >/dev/null 2>&1; then
    return 3
  fi

  short_name="${model##*/}"
  exact_count="$(printf '%s' "$models" | jq -r --arg m "$model" \
    '[.data[]? | select((.id | type) == "string" and .id == $m)] | length' 2>/dev/null)" || return 3
  short_count="$(printf '%s' "$models" | jq -r --arg s "$short_name" \
    '[.data[]? | select((.id | type) == "string" and .id == $s)] | length' 2>/dev/null)" || return 3
  case "$exact_count:$short_count" in
    *[!0-9:]*|'') return 3 ;;
  esac
  [[ "$exact_count" -le 1 && "$short_count" -le 1 ]] || return 3
  case "$model" in
    */*) [[ ! ( "$exact_count" -eq 1 && "$short_count" -eq 1 ) ]] || return 3 ;;
  esac

  if [[ "$exact_count" -eq 1 ]]; then
    selected="$model"
  elif [[ "$short_count" -eq 1 ]]; then
    selected="$short_name"
  else
    return 1
  fi
  OMLX_VISIBLE_MODEL_ID="$selected"

  case "$model" in
    */*) return 4 ;;
    *) return 0 ;;
  esac
}

# Inspect oMLX's authenticated admin inventory, whose current schema exposes
# source_repo_id for downloaded HuggingFace models. Return 0=proven requested
# repository, 1=no candidate, 2=conflicting or unproven candidate,
# 3=unreachable, 4=malformed/ambiguous. On success OMLX_PROVEN_MODEL_ID is the
# API-visible model ID associated with the exact repository.
_omlx_prove_repository() {
  local model="$1" base="$2" cookies="$3" curl_err="$4" expected_visible_id="${5:-}"
  local short_name="${model##*/}" inventory="" exact_count="" candidate_count=""
  local source_values="" model_id="" model_id_count=""
  OMLX_PROVEN_MODEL_ID=""

  case "$model" in
    */*) ;;
    *) OMLX_PROVEN_MODEL_ID="$model"; return 0 ;;
  esac

  if ! inventory="$(curl -fsS --connect-timeout 5 --max-time 10 \
      -b "$cookies" "$base/admin/api/models" 2>"$curl_err")"; then
    return 3
  fi
  if ! printf '%s' "$inventory" | jq -e '(.models | type) == "array"' >/dev/null 2>&1; then
    return 4
  fi

  exact_count="$(printf '%s' "$inventory" | jq -r --arg repo "$model" \
    '[.models[]? | select((.source_repo_id | type) == "string" and .source_repo_id == $repo)] | length' \
    2>/dev/null)" || return 4
  candidate_count="$(printf '%s' "$inventory" | jq -r --arg repo "$model" --arg short "$short_name" '
    [.models[]? | select(
      ((.id | type) == "string" and (.id == $repo or .id == $short)) or
      ((.display_name | type) == "string" and (.display_name == $repo or .display_name == $short))
    )] | length
  ' 2>/dev/null)" || return 4
  case "$exact_count:$candidate_count" in *[!0-9:]*|'') return 4 ;; esac
  [[ "$exact_count" -le 1 ]] || return 4

  if [[ "$exact_count" -eq 1 ]]; then
    model_id="$(printf '%s' "$inventory" | jq -er --arg repo "$model" '
      .models[] | select(.source_repo_id == $repo) |
      select((.id | type) == "string" and (.id | length) > 0) | .id
    ' 2>/dev/null)" || return 4
    _omlx_validate_scalar "$model_id" "oMLX proven model ID" || return 4
    model_id_count="$(printf '%s' "$inventory" | jq -r --arg id "$model_id" \
      '[.models[]? | select((.id | type) == "string" and .id == $id)] | length' \
      2>/dev/null)" || return 4
    case "$model_id_count" in ''|*[!0-9]*) return 4 ;; esac
    if [[ "$model_id_count" -ne 1 ]]; then
      echo "Error: oMLX admin inventory maps server model ID '$model_id' to multiple records" >&2
      return 2
    fi
    if [[ -n "$expected_visible_id" && "$model_id" != "$expected_visible_id" ]]; then
      echo "Error: oMLX public model ID '$expected_visible_id' is not the admin inventory entry for '$model'" >&2
      echo "  Proven repository is exposed as: $model_id" >&2
      return 2
    fi
    OMLX_PROVEN_MODEL_ID="$model_id"
    return 0
  fi

  [[ "$candidate_count" -eq 0 ]] && return 1

  source_values="$(printf '%s' "$inventory" | jq -r --arg repo "$model" --arg short "$short_name" '
    [.models[]? | select(
      ((.id | type) == "string" and (.id == $repo or .id == $short)) or
      ((.display_name | type) == "string" and (.display_name == $repo or .display_name == $short))
    ) | (.source_repo_id // "<unproven>")] | unique | join(", ")
  ' 2>/dev/null)" || source_values="<unproven>"
  echo "Error: oMLX model name '$short_name' is already present but cannot be proven to originate from '$model'" >&2
  echo "  Observed source identity: ${source_values:-<unproven>}" >&2
  return 2
}

_omlx_provenance_file() {
  local model="$1" base="$2" cache_dir="$3" short_name="${model##*/}" key=""
  key="$(launcher_profile_key "omlx-provenance-v1" "$base" "$short_name")" || return 1
  printf '%s/omlx-provenance/%s.json' "$cache_dir" "$key"
}

_omlx_write_provenance() {
  local file="$1" model="$2" base="$3" model_id="$4" short_name="${model##*/}" json=""
  mkdir -p "${file%/*}" || return 1
  json="$(jq -cn --arg base "$base" --arg short_name "$short_name" \
    --arg repo_id "$model" --arg model_id "$model_id" \
    '{version:1,base:$base,short_name:$short_name,repo_id:$repo_id,model_id:$model_id}')" || return 1
  printf '%s\n' "$json" | launcher_atomic_write_file "$file" 600 true
}

_omlx_verify_and_bind_repository() {
  local model="$1" base="$2" cookies="$3" curl_err="$4" cache_dir="$5" expected_visible_id="${6:-}"
  local status=0 provenance_file=""
  if _omlx_prove_repository "$model" "$base" "$cookies" "$curl_err" "$expected_visible_id"; then
    status=0
  else
    status=$?
  fi
  case "$status" in
    0)
      provenance_file="$(_omlx_provenance_file "$model" "$base" "$cache_dir")" || return 1
      _omlx_write_provenance "$provenance_file" "$model" "$base" "$OMLX_PROVEN_MODEL_ID" || {
        echo "Error: could not durably bind oMLX model provenance for $model" >&2
        return 1
      }
      return 0
      ;;
    1) return 1 ;;
    2) return 2 ;;
    3)
      echo "Error: could not contact the oMLX admin model inventory at $base" >&2
      [[ ! -s "$curl_err" ]] || sed 's/^/  /' "$curl_err" >&2
      return 3
      ;;
    4)
      echo "Error: oMLX returned a malformed or ambiguous admin model inventory" >&2
      return 4
      ;;
    *) return 4 ;;
  esac
}

_omlx_cancel_download() {
  local base="$1" cookies="$2" task_id="$3" encoded_task_id=""
  encoded_task_id="$(jq -rn --arg value "$task_id" '$value | @uri')" || return 1
  curl -fsS --connect-timeout 3 --max-time 10 \
    -b "$cookies" -X POST "$base/admin/api/hf/cancel/$encoded_task_id" \
    >/dev/null 2>&1
}

_omlx_write_task_marker() {
  local file="$1" state="$2" model="$3" base="$4" task_id="$5" json=""
  case "$state" in intent|active) ;; *) return 1 ;; esac
  if [[ "$state" == "active" ]]; then
    _omlx_validate_scalar "$task_id" "oMLX task ID" || return 1
  else
    task_id=""
  fi
  json="$(jq -cn --arg state "$state" --arg model "$model" --arg base "$base" \
    --arg task_id "$task_id" \
    '{version:1,state:$state,model:$model,base:$base,task_id:$task_id}')" || return 1
  printf '%s\n' "$json" | launcher_atomic_write_file "$file" 600 true
}

_omlx_read_task_marker() {
  local file="$1" expected_model="$2" expected_base="$3" json=""
  OMLX_MARKER_STATE=""
  OMLX_MARKER_TASK_ID=""
  if [[ -L "$file" || ! -f "$file" ]]; then
    echo "Error: invalid oMLX task journal object: $file" >&2
    return 1
  fi
  json="$(cat "$file")" || return 1
  if ! printf '%s' "$json" | jq -e --arg model "$expected_model" --arg base "$expected_base" '
      .version == 1 and
      (.state == "intent" or .state == "active") and
      .model == $model and .base == $base and
      (.task_id | type) == "string" and
      ((.state == "intent" and .task_id == "") or
       (.state == "active" and (.task_id | length) > 0))
    ' >/dev/null 2>&1; then
    echo "Error: malformed or mismatched oMLX task journal: $file" >&2
    return 1
  fi
  OMLX_MARKER_STATE="$(printf '%s' "$json" | jq -er '.state')" || return 1
  OMLX_MARKER_TASK_ID="$(printf '%s' "$json" | jq -er '.task_id')" || return 1
  [[ "$OMLX_MARKER_STATE" != "active" ]] || \
    _omlx_validate_scalar "$OMLX_MARKER_TASK_ID" "oMLX task ID" || return 1
}

_omlx_remove_task_marker() {
  local file="$1"
  if [[ -e "$file" || -L "$file" ]]; then
    if [[ -L "$file" || ! -f "$file" ]]; then
      echo "Error: refusing invalid oMLX task journal object: $file" >&2
      return 1
    fi
    rm -f "$file" || return 1
    launcher_sync_filesystem || return 1
  fi
}

# Populate OMLX_TASK_JSON and OMLX_TASK_STATE for exactly one task.
# Return 0=found, 1=missing, 2=unreachable, 3=malformed/duplicate.
_omlx_fetch_task_snapshot() {
  local base="$1" cookies="$2" task_id="$3" expected_model="$4" curl_err="$5"
  local tasks_json="" id_count="" match_count=""
  OMLX_TASK_JSON=""
  OMLX_TASK_STATE=""

  if ! tasks_json="$(curl -fsS --connect-timeout 5 --max-time 10 \
      -b "$cookies" "$base/admin/api/hf/tasks" 2>"$curl_err")"; then
    return 2
  fi
  if ! printf '%s' "$tasks_json" | jq -e '(.tasks | type) == "array"' >/dev/null 2>&1; then
    return 3
  fi
  id_count="$(printf '%s' "$tasks_json" | jq -r --arg id "$task_id" \
    '[.tasks[] | select(.task_id == $id)] | length' 2>/dev/null)" || return 3
  match_count="$(printf '%s' "$tasks_json" | jq -r --arg id "$task_id" --arg repo "$expected_model" \
    '[.tasks[] | select(.task_id == $id and .repo_id == $repo)] | length' 2>/dev/null)" || return 3
  case "$id_count:$match_count" in *[!0-9:]*|'') return 3 ;; esac
  [[ "$id_count" -ne 0 ]] || return 1
  [[ "$id_count" -eq 1 && "$match_count" -eq 1 ]] || return 3

  OMLX_TASK_JSON="$(printf '%s' "$tasks_json" | jq -ce --arg id "$task_id" --arg repo "$expected_model" \
    '.tasks[] | select(.task_id == $id and .repo_id == $repo)' 2>/dev/null)" || return 3
  OMLX_TASK_STATE="$(printf '%s' "$OMLX_TASK_JSON" | jq -er \
    'select((.status | type) == "string" and (.status | length) > 0) | .status' \
    2>/dev/null)" || return 3
  OMLX_TASK_STATE="$(printf '%s' "$OMLX_TASK_STATE" | tr '[:upper:]' '[:lower:]')"
}

_omlx_wait_for_model_visibility() {
  local model="$1" base="$2" api_key="$3"
  local timeout="${OMLX_MODEL_VISIBLE_TIMEOUT_SECONDS:-120}"
  local interval="${OMLX_MODEL_VISIBLE_POLL_SECONDS:-1}"
  local deadline=0 status=0 last="absent"
  case "$timeout" in ''|*[!0-9]*) timeout=120 ;; esac
  [[ "$timeout" -gt 0 ]] || timeout=120
  deadline=$((SECONDS + timeout))

  while [[ $SECONDS -lt $deadline ]]; do
    if _omlx_model_is_loaded "$model" "$base" "$api_key"; then
      return 0
    else
      status=$?
    fi
    case "$status" in
      1) last="not yet registered" ;;
      4) return 0 ;;
      2) last="server unreachable" ;;
      3)
        echo "Error: oMLX returned a malformed /v1/models response after downloading $model" >&2
        return 1
        ;;
      *) last="unexpected status $status" ;;
    esac
    sleep "$interval"
  done

  echo "Error: oMLX reported the download complete, but $model never appeared in /v1/models (${last})" >&2
  return 1
}

# The download path runs in a fresh Bash process so cookie, cancellation, and
# lock traps cannot replace traps installed by the calling launcher.
_omlx_download_model_inner() {
  local model="$1" base="$2" api_key="$3" hf_token="${4:-}" short_name="${1##*/}"
  local cache_dir="${FLOX_ENV_CACHE:?FLOX_ENV_CACHE is required}"
  local lock_key="" lock_file="" marker_file="" cookies="" curl_err=""
  local marker_present="false" marker_state="" marker_task_id=""
  local task_id="" task_active="false" task_terminal="false"
  local login_json="" status="" download_json="" resp=""
  local task="" state="" prog="0" error_text="" snapshot_status=0
  local deadline=0 loaded_status=0 provenance_status=0 model_ready="false"
  local network_failures=0 missing_polls=0
  local timeout="${OMLX_DOWNLOAD_TIMEOUT_SECONDS:-1800}"
  local interval="${OMLX_DOWNLOAD_POLL_SECONDS:-2}"
  local lock_wait="${OMLX_DOWNLOAD_LOCK_WAIT_SECONDS:-1800}"

  case "$timeout" in ''|*[!0-9]*) timeout=1800 ;; esac
  case "$lock_wait" in ''|*[!0-9]*) lock_wait=1800 ;; esac
  [[ "$timeout" -gt 0 ]] || timeout=1800
  [[ "$lock_wait" -gt 0 ]] || lock_wait=1800

  mkdir -p "$cache_dir/omlx-downloads" || {
    echo "Error: cannot create oMLX download cache directory" >&2
    return 1
  }
  lock_key="$(launcher_profile_key "omlx-download-v4" "$base" "$short_name")" || return 1
  lock_file="$cache_dir/omlx-downloads/${lock_key}.lock"
  marker_file="$cache_dir/omlx-downloads/${lock_key}.task"

  LAUNCHER_LOCK_FILE=""
  LAUNCHER_LOCK_FD=""

  _omlx_download_cleanup() {
    local cleanup_status=$? release_status=0
    if [[ "$task_active" == "true" && -n "$task_id" && -n "$cookies" ]]; then
      if _omlx_cancel_download "$base" "$cookies" "$task_id"; then
        task_active="false"
        if ! _omlx_remove_task_marker "$marker_file"; then
          echo "Warning: cancelled oMLX task $task_id but could not clear its durable journal" >&2
        fi
      else
        echo "Warning: could not cancel active oMLX download task $task_id; durable journal retained" >&2
      fi
    fi
    [[ -z "$cookies" ]] || rm -f "$cookies"
    [[ -z "$curl_err" ]] || rm -f "$curl_err"
    if launcher_lock_release; then
      :
    else
      release_status=$?
      [[ $cleanup_status -ne 0 ]] || cleanup_status=$release_status
    fi
    trap - EXIT
    exit "$cleanup_status"
  }
  trap '_omlx_download_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  launcher_lock_acquire "$lock_file" "$lock_wait" 120 "oMLX download for $model" || return 1

  if [[ -e "$marker_file" || -L "$marker_file" ]]; then
    _omlx_read_task_marker "$marker_file" "$model" "$base" || return 1
    marker_present="true"
    marker_state="$OMLX_MARKER_STATE"
    marker_task_id="$OMLX_MARKER_TASK_ID"
  fi

  if _omlx_model_is_loaded "$model" "$base" "$api_key"; then
    loaded_status=0
  else
    loaded_status=$?
  fi
  case "$loaded_status" in
    0)
      model_ready="true"
      [[ "$marker_present" == "true" ]] || return 0
      ;;
    1) ;;
    4) ;;
    2) echo "Error: could not contact oMLX models API at $base" >&2; return 1 ;;
    3) echo "Error: oMLX returned a malformed /v1/models response" >&2; return 1 ;;
    *) echo "Error: unexpected oMLX model-status result: $loaded_status" >&2; return 1 ;;
  esac

  cookies="$(mktemp -t omlx-cookies.XXXXXX)" || {
    echo "Error: could not create oMLX cookie jar" >&2
    return 1
  }
  curl_err="$(mktemp -t omlx-curl-error.XXXXXX)" || return 1
  chmod 600 "$cookies" "$curl_err" || return 1

  login_json="$(jq -cn --arg key "$api_key" '{api_key:$key}')" || {
    echo "Error: could not encode oMLX admin login request" >&2
    return 1
  }
  if ! status="$(printf '%s' "$login_json" | curl -sS -o /dev/null -w '%{http_code}' \
      --connect-timeout 5 --max-time 10 \
      -c "$cookies" \
      -X POST "$base/admin/api/login" \
      -H 'Content-Type: application/json' \
      --data-binary @- 2>"$curl_err")"; then
    echo "Error: could not contact the oMLX admin API at $base" >&2
    [[ ! -s "$curl_err" ]] || sed 's/^/  /' "$curl_err" >&2
    return 1
  fi
  if [[ "$status" != "200" ]]; then
    echo "Error: oMLX admin login failed (HTTP ${status:-unknown})" >&2
    echo "  Try: flox services restart omlx" >&2
    return 1
  fi

  case "$model" in
    */*)
      if _omlx_verify_and_bind_repository "$model" "$base" "$cookies" "$curl_err" "$cache_dir" "$OMLX_VISIBLE_MODEL_ID"; then
        provenance_status=0
      else
        provenance_status=$?
      fi
      case "$provenance_status" in
        0)
          [[ "$loaded_status" -eq 4 ]] && model_ready="true"
          ;;
        1)
          # No matching installed repository. A short-name model visible through
          # /v1/models without corresponding source provenance is unsafe.
          if [[ "$loaded_status" -eq 4 ]]; then
            echo "Error: visible oMLX model '$short_name' has no provable source repository" >&2
            return 1
          fi
          ;;
        2|3|4) return 1 ;;
        *) return 1 ;;
      esac
      ;;
    *) ;;
  esac

  if [[ "$model_ready" == "true" && "$marker_present" != "true" ]]; then
    return 0
  fi

  if [[ "$marker_present" == "true" ]]; then
    if [[ "$marker_state" == "intent" ]]; then
      if [[ "$model_ready" == "true" ]]; then
        _omlx_remove_task_marker "$marker_file" || return 1
        return 0
      fi
      echo "Error: prior oMLX download request for $model has an indeterminate outcome" >&2
      echo "  Durable journal retained at: $marker_file" >&2
      return 1
    fi

    task_id="$marker_task_id"
    if _omlx_fetch_task_snapshot "$base" "$cookies" "$task_id" "$model" "$curl_err"; then
      snapshot_status=0
      state="$OMLX_TASK_STATE"
      task="$OMLX_TASK_JSON"
    else
      snapshot_status=$?
    fi
    case "$snapshot_status" in
      0) ;;
      1)
        if [[ "$model_ready" == "true" ]]; then
          _omlx_remove_task_marker "$marker_file" || return 1
          return 0
        fi
        echo "Error: journaled oMLX task $task_id is absent; refusing a duplicate download" >&2
        return 1
        ;;
      2)
        echo "Error: could not recover journaled oMLX task $task_id because the task API is unreachable" >&2
        [[ ! -s "$curl_err" ]] || sed 's/^/  /' "$curl_err" >&2
        return 1
        ;;
      3)
        echo "Error: malformed task response while recovering journaled oMLX task $task_id" >&2
        return 1
        ;;
      *) return 1 ;;
    esac

    case "$state" in
      completed|complete|succeeded|success)
        task_terminal="true"
        ;;
      failed|error)
        error_text="$(printf '%s' "$task" | jq -r '.error // .message // "unknown error"' 2>/dev/null || true)"
        _omlx_remove_task_marker "$marker_file" || return 1
        [[ "$model_ready" != "true" ]] || return 0
        echo "Error: recovered oMLX task $task_id had failed: ${error_text:-unknown error}" >&2
        return 1
        ;;
      cancelled|canceled|aborted)
        _omlx_remove_task_marker "$marker_file" || return 1
        [[ "$model_ready" != "true" ]] || return 0
        echo "Error: recovered oMLX task $task_id was in terminal state '$state'" >&2
        return 1
        ;;
      pending|queued|running|downloading|processing|starting|in_progress|cancelling|canceling)
        task_active="true"
        ;;
      *)
        echo "Error: recovered oMLX task $task_id reported unknown status '$state'" >&2
        return 1
        ;;
    esac

    if [[ "$model_ready" == "true" ]]; then
      if [[ "$task_active" == "true" ]]; then
        if ! _omlx_cancel_download "$base" "$cookies" "$task_id"; then
          echo "Error: model is visible but duplicate journaled task $task_id could not be cancelled" >&2
          return 1
        fi
        task_active="false"
      fi
      _omlx_remove_task_marker "$marker_file" || return 1
      return 0
    fi
  fi

  if [[ "$task_terminal" == "true" ]]; then
    _omlx_wait_for_model_visibility "$model" "$base" "$api_key" || return 1
    case "$model" in
      */*) _omlx_verify_and_bind_repository "$model" "$base" "$cookies" "$curl_err" "$cache_dir" "$OMLX_VISIBLE_MODEL_ID" || return 1 ;;
    esac
    _omlx_remove_task_marker "$marker_file" || return 1
    echo "done." >&2
    return 0
  fi

  if [[ "$task_active" != "true" ]]; then
    if [[ -z "$hf_token" ]]; then
      hf_token="$(_hf_token_get "$model")" || return 1
    fi
    download_json="$(jq -cn --arg repo "$model" --arg token "$hf_token" \
      '{repo_id:$repo,hf_token:$token}')" || {
        echo "Error: could not encode oMLX download request" >&2
        return 1
      }
    echo "Downloading ${model}..." >&2
    _omlx_write_task_marker "$marker_file" intent "$model" "$base" "" || {
      echo "Error: cannot durably journal oMLX download intent" >&2
      return 1
    }
    marker_present="true"

    if ! resp="$(printf '%s' "$download_json" | curl -fsS \
        --connect-timeout 5 --max-time 30 \
        -b "$cookies" \
        -X POST "$base/admin/api/hf/download" \
        -H 'Content-Type: application/json' \
        --data-binary @- 2>"$curl_err")"; then
      echo "Error: failed to start download for ${model}; request outcome may be unknown" >&2
      echo "  Durable journal retained at: $marker_file" >&2
      [[ ! -s "$curl_err" ]] || sed 's/^/  /' "$curl_err" >&2
      return 1
    fi
    task_id="$(printf '%s' "$resp" | jq -er --arg repo "$model" '
      select(
        .success == true and
        (.task.task_id | type) == "string" and (.task.task_id | length) > 0 and
        (.task.repo_id | type) == "string" and .task.repo_id == $repo
      ) | .task.task_id
    ' 2>/dev/null)" || {
      echo "Error: malformed oMLX download-start response for ${model}; request outcome is unknown" >&2
      echo "  Durable journal retained at: $marker_file" >&2
      return 1
    }
    _omlx_validate_scalar "$task_id" "oMLX task ID" || return 1
    # Make cleanup cancellation authoritative as soon as the remote task ID is
    # known, including interruption during durable journal publication.
    task_active="true"
    _omlx_write_task_marker "$marker_file" active "$model" "$base" "$task_id" || {
      echo "Error: oMLX task $task_id started, but its durable journal could not be committed" >&2
      return 1
    }
  else
    echo "Resuming oMLX download task $task_id for ${model}..." >&2
  fi

  deadline=$((SECONDS + timeout))
  while [[ $SECONDS -lt $deadline ]]; do
    if _omlx_fetch_task_snapshot "$base" "$cookies" "$task_id" "$model" "$curl_err"; then
      snapshot_status=0
      state="$OMLX_TASK_STATE"
      task="$OMLX_TASK_JSON"
    else
      snapshot_status=$?
    fi

    case "$snapshot_status" in
      0)
        network_failures=0
        missing_polls=0
        ;;
      1)
        missing_polls=$((missing_polls + 1))
        if [[ $missing_polls -ge 3 ]]; then
          printf '\n' >&2
          echo "Error: oMLX download task $task_id vanished before reaching a terminal state" >&2
          return 1
        fi
        sleep "$interval"
        continue
        ;;
      2)
        network_failures=$((network_failures + 1))
        if [[ $network_failures -ge 3 ]]; then
          printf '\n' >&2
          echo "Error: oMLX task API became unreachable while downloading $model" >&2
          [[ ! -s "$curl_err" ]] || sed 's/^/  /' "$curl_err" >&2
          return 1
        fi
        sleep "$interval"
        continue
        ;;
      3)
        printf '\n' >&2
        echo "Error: oMLX returned a malformed or duplicate download-task response" >&2
        return 1
        ;;
      *) return 1 ;;
    esac

    case "$state" in
      completed|complete|succeeded|success)
        task_active="false"
        task_terminal="true"
        printf '\r\033[K' >&2
        echo "download complete; waiting for model registration..." >&2
        break
        ;;
      failed|error)
        task_active="false"
        error_text="$(printf '%s' "$task" | jq -r '.error // .message // "unknown error"' 2>/dev/null || true)"
        _omlx_remove_task_marker "$marker_file" || return 1
        printf '\n' >&2
        echo "Error: oMLX download failed: ${error_text:-unknown error}" >&2
        return 1
        ;;
      cancelled|canceled|aborted)
        task_active="false"
        _omlx_remove_task_marker "$marker_file" || return 1
        printf '\n' >&2
        echo "Error: oMLX download entered terminal state '$state'" >&2
        return 1
        ;;
      pending|queued|running|downloading|processing|starting|in_progress|cancelling|canceling)
        prog="$(printf '%s' "$task" | jq -r '(.progress // 0) | tonumber? // 0' 2>/dev/null || printf '0')"
        printf '\r  %s  %.1f%%' "$state" "$prog" >&2
        ;;
      *)
        printf '\n' >&2
        echo "Error: oMLX task $task_id reported unknown status '$state'" >&2
        return 1
        ;;
    esac
    sleep "$interval"
  done

  if [[ "$task_terminal" != "true" ]]; then
    printf '\n' >&2
    echo "Error: oMLX download timed out after ${timeout}s (last state: ${state:-unknown})" >&2
    return 1
  fi

  _omlx_wait_for_model_visibility "$model" "$base" "$api_key" || return 1
  case "$model" in
    */*) _omlx_verify_and_bind_repository "$model" "$base" "$cookies" "$curl_err" "$cache_dir" "$OMLX_VISIBLE_MODEL_ID" || return 1 ;;
  esac
  _omlx_remove_task_marker "$marker_file" || return 1
  echo "done." >&2
}

# Run the trap-owning implementation as a child while forwarding launcher
# signals to it. Without this wrapper, a signal delivered to the launcher shell
# could terminate the waiting parent and leave the download child—and therefore
# the server-side task—running.
_omlx_download_model() {
  local child_pid="" status=0 signal_status=0 helper_path="${BASH_SOURCE[0]}"
  local old_int="" old_term="" old_hup=""

  old_int="$(trap -p INT || true)"
  old_term="$(trap -p TERM || true)"
  old_hup="$(trap -p HUP || true)"

  # Start a fresh Bash process rather than an asynchronous shell function.
  # On Bash 3.2, $$ is not updated in an async subshell. A fresh interpreter
  # also makes signal forwarding and trap-owned remote-task cleanup explicit,
  # while its protected children inherit the worker's kernel-lock descriptor.
  "${BASH:-bash}" -c     'source "$1"; shift; _omlx_download_model_inner "$@"'     _ "$helper_path" "$@" &
  child_pid=$!
  trap 'signal_status=130; kill -INT "$child_pid" 2>/dev/null || true' INT
  trap 'signal_status=143; kill -TERM "$child_pid" 2>/dev/null || true' TERM
  trap 'signal_status=129; kill -HUP "$child_pid" 2>/dev/null || true' HUP

  if wait "$child_pid"; then
    status=0
  else
    status=$?
  fi
  if [[ "$signal_status" -ne 0 ]]; then
    while kill -0 "$child_pid" 2>/dev/null; do
      if wait "$child_pid"; then status=0; else status=$?; fi
    done
    status="$signal_status"
  fi

  trap - INT TERM HUP
  [[ -z "$old_int" ]] || eval "$old_int"
  [[ -z "$old_term" ]] || eval "$old_term"
  [[ -z "$old_hup" ]] || eval "$old_hup"
  return "$status"
}

omlx_ensure_model() {
  local model="$1" host="$2" port="$3" base="" endpoint_label=""
  local n=0 code="" loaded_status=0 visible_id=""
  local ready_attempts="${OMLX_READY_ATTEMPTS:-30}"
  local ready_interval="${OMLX_READY_POLL_SECONDS:-1}"

  _omlx_validate_scalar "$model" "oMLX model" || return 1
  base="$(_omlx_base_url "$host" "$port")" || return 1
  endpoint_label="${base#http://}"
  case "$ready_attempts" in ''|*[!0-9]*) ready_attempts=30 ;; esac
  [[ "$ready_attempts" -gt 0 ]] || ready_attempts=30

  while true; do
    n=$((n + 1))
    if [[ $n -gt $ready_attempts ]]; then
      echo "Error: oMLX at $endpoint_label did not become ready in time" >&2
      echo "  Is oMLX running? Try: flox services status" >&2
      return 1
    fi
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
      --connect-timeout 1 --max-time 2 \
      "$base/v1/models" 2>/dev/null || true)"
    [[ "$code" == "200" || "$code" == "401" ]] && break
    sleep "$ready_interval"
  done

  OMLX_API_KEY="$(_omlx_key_get "$base" "$endpoint_label")" || return 1
  export OMLX_API_KEY

  if _omlx_model_is_loaded "$model" "$base" "$OMLX_API_KEY"; then
    OMLX_MODEL_ID="$OMLX_VISIBLE_MODEL_ID"
    export OMLX_MODEL_ID
    return 0
  else
    loaded_status=$?
    visible_id="$OMLX_VISIBLE_MODEL_ID"
  fi
  case "$loaded_status" in
    1|4) ;;
    2)
      echo "Error: could not contact oMLX models API at $base" >&2
      return 1
      ;;
    3)
      echo "Error: oMLX returned a malformed /v1/models response" >&2
      return 1
      ;;
    *)
      echo "Error: unexpected oMLX model-status result: $loaded_status" >&2
      return 1
      ;;
  esac

  # Full owner/repository IDs deliberately pass through the authenticated
  # provenance path even when /v1/models exposes a matching short name.
  _omlx_download_model "$model" "$base" "$OMLX_API_KEY" "" || return 1

  # Defensive public postcondition: the model must be discoverable through the
  # same endpoint and credentials. A full repository returns status 4 here by
  # design; the child has already proven and durably bound its source identity.
  if _omlx_model_is_loaded "$model" "$base" "$OMLX_API_KEY"; then
    loaded_status=0
  else
    loaded_status=$?
  fi
  case "$loaded_status" in
    0|4)
      OMLX_MODEL_ID="$OMLX_VISIBLE_MODEL_ID"
      _omlx_validate_scalar "$OMLX_MODEL_ID" "oMLX model ID" || return 1
      export OMLX_MODEL_ID
      return 0
      ;;
  esac
  echo "Error: oMLX ensure postcondition failed for $model (status $loaded_status)" >&2
  return 1
}
