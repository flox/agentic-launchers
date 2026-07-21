# Shared helper — sourced by launch-* wrappers.

case "${BASH_SOURCE[0]}" in
  */*) _OLLAMA_HELPER_DIR="${BASH_SOURCE[0]%/*}" ;;
  *) _OLLAMA_HELPER_DIR="." ;;
esac
_OLLAMA_HELPER_DIR="$(cd -- "$_OLLAMA_HELPER_DIR" && pwd -P)" || return 1
source "$_OLLAMA_HELPER_DIR/_launcher-common.sh"
unset _OLLAMA_HELPER_DIR

_ollama_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# Normalize OLLAMA_HOST using Ollama's URL semantics while preserving the
# bundle's optional OLLAMA_PORT override when OLLAMA_HOST has no explicit port.
# Outputs globals:
#   OLLAMA_BASE_URL, OLLAMA_SCHEME, OLLAMA_CONNECT_HOST, OLLAMA_PORT, OLLAMA_PATH
ollama_normalize_base_url() {
  local raw="${OLLAMA_HOST:-}" rest="" scheme="" authority="" path=""
  local host="" port="" default_port="" explicit_port="false" after="" first=""
  local had_scheme="false" url_host=""

  raw="$(_ollama_trim "$raw")"
  case "$raw" in
    \"*\") raw="${raw#\"}"; raw="${raw%\"}" ;;
    \'*\') raw="${raw#\'}"; raw="${raw%\'}" ;;
  esac
  [[ -n "$raw" ]] || raw="127.0.0.1"

  case "$raw" in
    *://*)
      had_scheme="true"
      scheme="${raw%%://*}"
      rest="${raw#*://}"
      ;;
    *)
      scheme="http"
      rest="$raw"
      ;;
  esac
  scheme="$(printf '%s' "$scheme" | tr '[:upper:]' '[:lower:]')" || return 1
  case "$scheme" in
    http)  [[ "$had_scheme" == "true" ]] && default_port=80 || default_port=11434 ;;
    https) default_port=443 ;;
    *)
      echo "Error: unsupported OLLAMA_HOST scheme: $scheme" >&2
      return 1
      ;;
  esac

  if [[ "$had_scheme" != "true" && "$rest" == "ollama.com" ]]; then
    scheme="https"
    default_port=443
  fi
  case "$rest" in
    *\?*|*\#*)
      echo "Error: OLLAMA_HOST must not contain a query or fragment" >&2
      return 1
      ;;
  esac

  authority="${rest%%/*}"
  if [[ "$rest" == */* ]]; then
    path="/${rest#*/}"
  fi
  while [[ "$path" == */ && -n "$path" ]]; do
    path="${path%/}"
  done

  if [[ "$authority" == \[* ]]; then
    if [[ "$authority" != *\]* ]]; then
      echo "Error: invalid bracketed IPv6 OLLAMA_HOST: $authority" >&2
      return 1
    fi
    host="${authority%%]*}"
    host="${host#[}"
    after="${authority#*]}"
    if [[ -n "$after" ]]; then
      case "$after" in
        :*) port="${after#:}"; explicit_port="true" ;;
        *)
          echo "Error: invalid OLLAMA_HOST authority: $authority" >&2
          return 1
          ;;
      esac
    fi
  elif [[ "$authority" == *:* ]]; then
    first="${authority%%:*}"
    after="${authority#*:}"
    if [[ "$after" != *:* ]]; then
      host="$first"
      port="$after"
      explicit_port="true"
    else
      # Multiple colons without brackets are a bare IPv6 literal.
      host="$authority"
    fi
  else
    host="$authority"
  fi

  [[ -n "$host" ]] || host="127.0.0.1"
  if [[ "$host" == "0.0.0.0" ]]; then
    host="127.0.0.1"
  elif [[ "$host" == "::" ]]; then
    host="::1"
  fi

  if [[ "$explicit_port" != "true" && -n "${OLLAMA_PORT:-}" ]]; then
    port="$OLLAMA_PORT"
  fi
  [[ -n "$port" ]] || port="$default_port"
  case "$port" in
    ''|*[!0-9]*)
      echo "Error: invalid OLLAMA_HOST port: $port" >&2
      return 1
      ;;
  esac
  if [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
    echo "Error: invalid OLLAMA_HOST port: $port" >&2
    return 1
  fi

  url_host="$host"
  if [[ "$url_host" == *:* ]]; then
    url_host="[$url_host]"
  fi

  OLLAMA_SCHEME="$scheme"
  OLLAMA_CONNECT_HOST="$host"
  OLLAMA_PORT="$port"
  OLLAMA_PATH="$path"
  OLLAMA_BASE_URL="${scheme}://${url_host}:${port}${path}"
  # Export the canonical complete URL under Ollama's standard variable.
  OLLAMA_HOST="$OLLAMA_BASE_URL"
  export OLLAMA_HOST OLLAMA_PORT OLLAMA_BASE_URL
}

# Backward-compatible name retained for any external launcher that sourced the
# old helper. Its postcondition is now the complete OLLAMA_BASE_URL above.
ollama_normalize_host_port() {
  ollama_normalize_base_url
}

# Return 0 if present, 1 if absent, 2 if unreachable, 3 if malformed.
_ollama_model_status() {
  local model="$1" base="$2" tags="" jq_status=0
  if ! tags="$(curl -fsS --connect-timeout 5 --max-time 10 "$base/api/tags" 2>/dev/null)"; then
    return 2
  fi
  if printf '%s' "$tags" | jq -e --arg m "$model" \
      'if (.models | type) == "array"
       then any(.models[]; (.name // .model // "") == $m)
       else error("invalid tags response")
       end' >/dev/null 2>&1; then
    return 0
  else
    jq_status=$?
  fi
  [[ $jq_status -eq 1 ]] && return 1
  return 3
}

_ollama_report_status_error() {
  local status="$1" base="$2"
  case "$status" in
    2) echo "Error: cannot reach ollama at $base" >&2 ;;
    3) echo "Error: ollama returned a malformed /api/tags response from $base" >&2 ;;
    *) return 1 ;;
  esac
}

# Ensures a model exists in Ollama. Pulls for the same endpoint/model are
# serialized, followed by a bounded postcondition check against /api/tags.
# A durable intent journal prevents a launcher crash or indeterminate HTTP
# outcome from causing a second potentially expensive pull request.
_ollama_write_pull_marker() {
  local file="$1" model="$2" base="$3" now="" json=""
  now="$(date +%s)" || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  json="$(jq -cn --arg model "$model" --arg base "$base" --argjson started_at "$now" \
    '{version:1,state:"intent",model:$model,base:$base,started_at:$started_at}')" || return 1
  printf '%s\n' "$json" | launcher_atomic_write_file "$file" 600 true
}

_ollama_validate_pull_marker() {
  local file="$1" expected_model="$2" expected_base="$3" json=""
  if [[ -L "$file" || ! -f "$file" ]]; then
    echo "Error: invalid Ollama pull journal object: $file" >&2
    return 1
  fi
  json="$(cat "$file")" || return 1
  if ! printf '%s' "$json" | jq -e --arg model "$expected_model" --arg base "$expected_base" '
      .version == 1 and .state == "intent" and
      .model == $model and .base == $base and
      (.started_at | type) == "number" and .started_at >= 0
    ' >/dev/null 2>&1; then
    echo "Error: malformed or mismatched Ollama pull journal: $file" >&2
    return 1
  fi
}

_ollama_remove_pull_marker() {
  local file="$1"
  if [[ -e "$file" || -L "$file" ]]; then
    if [[ -L "$file" || ! -f "$file" ]]; then
      echo "Error: refusing invalid Ollama pull journal object: $file" >&2
      return 1
    fi
    rm -f "$file" || return 1
    launcher_sync_filesystem || return 1
  fi
}

_ollama_wait_for_model() {
  local model="$1" base="$2" timeout="$3" interval="${4:-1}"
  local deadline=0 status=0
  case "$timeout" in ''|*[!0-9]*) return 2 ;; esac
  [[ "$timeout" -gt 0 ]] || return 2
  deadline=$((SECONDS + timeout))
  while [[ $SECONDS -lt $deadline ]]; do
    if _ollama_model_status "$model" "$base"; then
      return 0
    else
      status=$?
    fi
    case "$status" in
      1) sleep "$interval" ;;
      2|3) return "$status" ;;
      *) return 3 ;;
    esac
  done
  return 1
}

ollama_ensure_model() (
  local model="$1" base="${2:-}" normalized="$1" status=0 key="" lock_file="" marker_file=""
  local pull_json="" pull_output="" pull_error="" pull_success="false"
  local verify_timeout="${OLLAMA_PULL_VERIFY_SECONDS:-30}"
  local recovery_timeout="${OLLAMA_PULL_RECOVERY_SECONDS:-30}"

  if [[ -z "$base" ]]; then
    echo "Error: ollama_ensure_model requires a base URL" >&2
    return 1
  fi
  if [[ "${model##*/}" != *:* ]]; then
    normalized="${model}:latest"
  fi
  case "$verify_timeout" in ''|*[!0-9]*) verify_timeout=30 ;; esac
  case "$recovery_timeout" in ''|*[!0-9]*) recovery_timeout=30 ;; esac
  [[ "$verify_timeout" -gt 0 ]] || verify_timeout=30
  [[ "$recovery_timeout" -gt 0 ]] || recovery_timeout=30

  key="$(launcher_profile_key "ollama-pull-v2" "$base" "$normalized")" || return 1
  lock_file="${FLOX_ENV_CACHE:?FLOX_ENV_CACHE is required}/ollama-pulls/${key}.lock"
  marker_file="${FLOX_ENV_CACHE}/ollama-pulls/${key}.intent"

  if _ollama_model_status "$normalized" "$base"; then
    if [[ ! -e "$marker_file" && ! -L "$marker_file" ]]; then
      return 0
    fi
  else
    status=$?
    if [[ $status -ne 1 ]]; then
      _ollama_report_status_error "$status" "$base"
      return 1
    fi
  fi

  LAUNCHER_LOCK_FILE=""
  LAUNCHER_LOCK_FD=""
  launcher_lock_acquire "$lock_file" 900 120 "Ollama pull for $normalized" || return 1
  _ollama_lock_cleanup() {
    local cleanup_status=$? release_status=0
    if launcher_lock_release; then
      :
    else
      release_status=$?
      [[ $cleanup_status -ne 0 ]] || cleanup_status=$release_status
    fi
    trap - EXIT
    exit "$cleanup_status"
  }
  trap '_ollama_lock_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  # Another launcher may have completed the pull while this one waited.
  if _ollama_model_status "$normalized" "$base"; then
    _ollama_remove_pull_marker "$marker_file" || return 1
    return 0
  else
    status=$?
    if [[ $status -ne 1 ]]; then
      _ollama_report_status_error "$status" "$base"
      return 1
    fi
  fi

  # A journal surviving without a visible model means a previous POST may still
  # be running server-side. Since Ollama exposes no task identity for /api/pull,
  # wait for its postcondition and fail closed rather than issuing a duplicate.
  if [[ -e "$marker_file" || -L "$marker_file" ]]; then
    _ollama_validate_pull_marker "$marker_file" "$normalized" "$base" || return 1
    echo "Waiting for a previously started Ollama pull of ${normalized}..." >&2
    if _ollama_wait_for_model "$normalized" "$base" "$recovery_timeout" 1; then
      _ollama_remove_pull_marker "$marker_file" || return 1
      echo "done." >&2
      return 0
    else
      status=$?
    fi
    case "$status" in
      1)
        echo "Error: prior Ollama pull outcome remains indeterminate for ${normalized}" >&2
        echo "  Refusing a duplicate pull; durable journal retained at: $marker_file" >&2
        ;;
      2) echo "Error: Ollama became unreachable while recovering ${normalized}" >&2 ;;
      3) echo "Error: Ollama returned malformed model data while recovering ${normalized}" >&2 ;;
      *) echo "Error: unexpected Ollama recovery status: $status" >&2 ;;
    esac
    return 1
  fi

  _ollama_write_pull_marker "$marker_file" "$normalized" "$base" || {
    echo "Error: cannot durably journal Ollama pull intent for ${normalized}" >&2
    return 1
  }

  pull_json="$(jq -cn --arg name "$model" '{name:$name}')" || {
    echo "Error: could not encode Ollama pull request" >&2
    return 1
  }
  echo "Pulling ${normalized}..." >&2
  if ! pull_output="$(printf '%s' "$pull_json" | curl -sS --connect-timeout 5 --max-time 600 \
      -H 'Content-Type: application/json' \
      "$base/api/pull" --data-binary @- 2>&1)"; then
    echo "Error: request to pull ${normalized} failed; outcome may be unknown: ${pull_output}" >&2
    echo "  Durable journal retained at: $marker_file" >&2
    return 1
  fi

  if ! printf '%s\n' "$pull_output" | jq -e . >/dev/null 2>&1; then
    echo "Error: Ollama returned malformed pull progress for ${normalized}; outcome is unknown" >&2
    echo "  Durable journal retained at: $marker_file" >&2
    return 1
  fi
  pull_error="$(printf '%s\n' "$pull_output" | jq -r 'select(.error != null) | .error' 2>/dev/null | tail -1 || true)"
  if [[ -n "$pull_error" ]]; then
    _ollama_remove_pull_marker "$marker_file" || return 1
    echo "Error: failed to pull ${normalized}: ${pull_error}" >&2
    return 1
  fi
  if printf '%s\n' "$pull_output" | jq -e 'select(.status == "success")' >/dev/null 2>&1; then
    pull_success="true"
  fi
  if [[ "$pull_success" != "true" ]]; then
    echo "Error: Ollama pull for ${normalized} ended without a success record; outcome is unknown" >&2
    echo "  Durable journal retained at: $marker_file" >&2
    return 1
  fi

  if _ollama_wait_for_model "$normalized" "$base" "$verify_timeout" 1; then
    _ollama_remove_pull_marker "$marker_file" || return 1
    echo "done." >&2
    return 0
  else
    status=$?
  fi
  case "$status" in
    1) echo "Error: Ollama reported pull success, but ${normalized} never appeared in /api/tags" >&2 ;;
    2) echo "Error: Ollama became unreachable while verifying ${normalized}" >&2 ;;
    3) echo "Error: Ollama returned malformed model data while verifying ${normalized}" >&2 ;;
    *) echo "Error: unexpected Ollama verification status: $status" >&2 ;;
  esac
  echo "  Durable journal retained at: $marker_file" >&2
  return 1
)
