# Shared helper — sourced by launch scripts that use llamacpp-proxy services.
# The service reads <cache>/<service>.model as desired model state. Separate
# committed and transition records bind that model to the complete launcher-side
# service configuration identity, so health for an old upstream/configuration is
# never accepted as proof of the current request.

case "${BASH_SOURCE[0]}" in
  */*) _PROXY_HELPER_DIR="${BASH_SOURCE[0]%/*}" ;;
  *) _PROXY_HELPER_DIR="." ;;
esac
_PROXY_HELPER_DIR="$(cd -- "$_PROXY_HELPER_DIR" && pwd -P)" || return 1
source "$_PROXY_HELPER_DIR/_launcher-common.sh"
unset _PROXY_HELPER_DIR

_proxy_base_url() {
  local listen="$1"
  case "$listen" in
    http://*|https://*) ;;
    *) listen="http://${listen}" ;;
  esac
  while [[ "$listen" == */ ]]; do listen="${listen%/}"; done
  _proxy_validate_scalar "$listen" "proxy URL" || return 1
  printf '%s' "$listen"
}

_proxy_healthcheck() {
  local listen="$1" base=""
  base="$(_proxy_base_url "$listen")" || return 1
  curl -fsS --connect-timeout 1 --max-time 2 "$base/health" >/dev/null 2>&1
}

_proxy_validate_scalar() {
  local value="$1" label="$2"
  if [[ -z "$value" || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "Error: invalid $label value" >&2
    return 1
  fi
}

_proxy_read_scalar_file() {
  local file="$1" label="$2" value=""
  if [[ -L "$file" || ! -f "$file" ]]; then
    echo "Error: invalid $label state object: $file" >&2
    return 1
  fi
  value="$(cat "$file")" || {
    echo "Error: cannot read $label state: $file" >&2
    return 1
  }
  _proxy_validate_scalar "$value" "$label" || return 1
  printf '%s' "$value"
}

_proxy_write_scalar_file() {
  local file="$1" value="$2" label="$3"
  _proxy_validate_scalar "$value" "$label" || return 1
  if ! printf '%s' "$value" | launcher_atomic_write_file "$file" 600 true; then
    echo "Error: cannot durably update $label state: $file" >&2
    return 1
  fi
}

_proxy_remove_durable() {
  local file="$1"
  if [[ -e "$file" || -L "$file" ]]; then
    if [[ -L "$file" || ! -f "$file" ]]; then
      echo "Error: refusing invalid proxy transaction object: $file" >&2
      return 1
    fi
    rm -f "$file" || return 1
    launcher_sync_filesystem || return 1
  fi
}

_proxy_make_record() {
  local service="$1" model="$2" listen="$3" runtime_id="$4" identity="$5"
  local expected_identity=""
  _proxy_validate_scalar "$service" "proxy service" || return 1
  _proxy_validate_scalar "$model" "proxy model" || return 1
  _proxy_validate_scalar "$listen" "proxy listen URL" || return 1
  _proxy_validate_scalar "$runtime_id" "proxy runtime identity" || return 1
  _proxy_validate_scalar "$identity" "proxy applied identity" || return 1
  expected_identity="$(launcher_profile_key "proxy-applied-v2" "$service" "$model" "$runtime_id")" || return 1
  if [[ "$identity" != "$expected_identity" ]]; then
    echo "Error: refusing internally inconsistent new proxy record" >&2
    return 1
  fi
  jq -cn --arg service "$service" --arg model "$model" --arg listen "$listen" \
    --arg runtime_id "$runtime_id" --arg identity "$identity" \
    '{version:2,service:$service,model:$model,listen:$listen,runtime_id:$runtime_id,identity:$identity}'
}

_proxy_parse_record() {
  local json="$1" label="$2" parsed="" expected_identity="" normalized_listen=""
  PROXY_RECORD_SERVICE=""
  PROXY_RECORD_MODEL=""
  PROXY_RECORD_LISTEN=""
  PROXY_RECORD_RUNTIME_ID=""
  PROXY_RECORD_IDENTITY=""

  # Hashes are canonical lowercase SHA-256 values. Requiring one spelling avoids
  # case-normalization ambiguity on Bash 3.2 and makes serialized records stable.
  parsed="$(printf '%s' "$json" | jq -ce '
    select(
      (keys | sort) == ["identity","listen","model","runtime_id","service","version"] and
      .version == 2 and
      (.service | type) == "string" and (.service | length) > 0 and
      (.model | type) == "string" and (.model | length) > 0 and
      (.listen | type) == "string" and (.listen | length) > 0 and
      (.runtime_id | type) == "string" and (.runtime_id | test("^[0-9a-f]{64}$")) and
      (.identity | type) == "string" and (.identity | test("^[0-9a-f]{64}$"))
    )
  ' 2>/dev/null)" || {
    echo "Error: malformed $label proxy state" >&2
    return 1
  }

  PROXY_RECORD_SERVICE="$(printf '%s' "$parsed" | jq -er '.service')" || return 1
  PROXY_RECORD_MODEL="$(printf '%s' "$parsed" | jq -er '.model')" || return 1
  PROXY_RECORD_LISTEN="$(printf '%s' "$parsed" | jq -er '.listen')" || return 1
  PROXY_RECORD_RUNTIME_ID="$(printf '%s' "$parsed" | jq -er '.runtime_id')" || return 1
  PROXY_RECORD_IDENTITY="$(printf '%s' "$parsed" | jq -er '.identity')" || return 1

  _proxy_validate_scalar "$PROXY_RECORD_SERVICE" "$label proxy service" || return 1
  _proxy_validate_scalar "$PROXY_RECORD_MODEL" "$label proxy model" || return 1
  _proxy_validate_scalar "$PROXY_RECORD_LISTEN" "$label proxy listen URL" || return 1
  normalized_listen="$(_proxy_base_url "$PROXY_RECORD_LISTEN")" || return 1
  if [[ "$PROXY_RECORD_LISTEN" != "$normalized_listen" ]]; then
    echo "Error: non-canonical $label proxy listen URL" >&2
    return 1
  fi

  expected_identity="$(launcher_profile_key \
    "proxy-applied-v2" \
    "$PROXY_RECORD_SERVICE" \
    "$PROXY_RECORD_MODEL" \
    "$PROXY_RECORD_RUNTIME_ID")" || return 1
  if [[ "$PROXY_RECORD_IDENTITY" != "$expected_identity" ]]; then
    echo "Error: internally inconsistent $label proxy state" >&2
    return 1
  fi
}

_proxy_record_matches_request() {
  local record_service="$1" record_model="$2" record_listen="$3"
  local record_runtime_id="$4" record_identity="$5"
  local service="$6" model="$7" listen="$8" runtime_id="$9"
  shift 9
  local identity="$1"
  [[ "$record_service" == "$service" \
      && "$record_model" == "$model" \
      && "$record_listen" == "$listen" \
      && "$record_runtime_id" == "$runtime_id" \
      && "$record_identity" == "$identity" ]]
}

_proxy_read_committed() {
  local file="$1" content=""
  PROXY_COMMITTED_VERSION=""
  PROXY_COMMITTED_JSON=""
  PROXY_COMMITTED_SERVICE=""
  PROXY_COMMITTED_MODEL=""
  PROXY_COMMITTED_LISTEN=""
  PROXY_COMMITTED_RUNTIME_ID=""
  PROXY_COMMITTED_IDENTITY=""

  if [[ -L "$file" || ! -f "$file" ]]; then
    echo "Error: invalid proxy committed-state object: $file" >&2
    return 1
  fi
  content="$(cat "$file")" || return 1

  if [[ "$content" == \{* ]]; then
    _proxy_parse_record "$content" "committed" || return 1
    PROXY_COMMITTED_VERSION="2"
    PROXY_COMMITTED_JSON="$content"
    PROXY_COMMITTED_SERVICE="$PROXY_RECORD_SERVICE"
    PROXY_COMMITTED_MODEL="$PROXY_RECORD_MODEL"
    PROXY_COMMITTED_LISTEN="$PROXY_RECORD_LISTEN"
    PROXY_COMMITTED_RUNTIME_ID="$PROXY_RECORD_RUNTIME_ID"
    PROXY_COMMITTED_IDENTITY="$PROXY_RECORD_IDENTITY"
  else
    # Schema-v1 bundles stored only the model. Preserve upgrade compatibility,
    # but never accept the legacy record as a complete applied-state identity.
    _proxy_validate_scalar "$content" "legacy proxy committed model" || return 1
    PROXY_COMMITTED_VERSION="1"
    PROXY_COMMITTED_MODEL="$content"
  fi
}

_proxy_write_committed() {
  local file="$1" record="$2"
  _proxy_parse_record "$record" "new committed" || return 1
  if ! printf '%s\n' "$record" | launcher_atomic_write_file "$file" 600 true; then
    echo "Error: cannot durably update proxy committed state: $file" >&2
    return 1
  fi
}

_proxy_write_transition() {
  local file="$1" target="$2" previous_present="$3" previous="$4" json=""
  _proxy_parse_record "$target" "transition target" || return 1
  case "$previous_present" in true|false) ;; *) return 1 ;; esac
  if [[ "$previous_present" == "true" ]]; then
    _proxy_parse_record "$previous" "transition previous" || return 1
  else
    previous='null'
  fi
  json="$(jq -cn --argjson target "$target" --argjson previous_present "$previous_present" \
    --argjson previous "$previous" \
    '{version:2,target:$target,previous_present:$previous_present,previous:(if $previous_present then $previous else null end)}')" || return 1
  printf '%s\n' "$json" | launcher_atomic_write_file "$file" 600 true
}

_proxy_read_transition() {
  local file="$1" json="" version=""
  PROXY_TRANSITION_VERSION=""
  PROXY_TRANSITION_TARGET_JSON=""
  PROXY_TRANSITION_TARGET_SERVICE=""
  PROXY_TRANSITION_TARGET_MODEL=""
  PROXY_TRANSITION_TARGET_LISTEN=""
  PROXY_TRANSITION_TARGET_RUNTIME_ID=""
  PROXY_TRANSITION_TARGET_IDENTITY=""
  PROXY_TRANSITION_PREVIOUS_PRESENT="false"
  PROXY_TRANSITION_PREVIOUS_JSON=""
  PROXY_TRANSITION_PREVIOUS_SERVICE=""
  PROXY_TRANSITION_PREVIOUS_MODEL=""
  PROXY_TRANSITION_PREVIOUS_LISTEN=""
  PROXY_TRANSITION_PREVIOUS_RUNTIME_ID=""
  PROXY_TRANSITION_PREVIOUS_IDENTITY=""

  if [[ -L "$file" || ! -f "$file" ]]; then
    echo "Error: invalid proxy transition object: $file" >&2
    return 1
  fi
  json="$(cat "$file")" || return 1
  version="$(printf '%s' "$json" | jq -er '.version' 2>/dev/null)" || {
    echo "Error: malformed proxy transition state: $file" >&2
    return 1
  }

  if [[ "$version" == "2" ]]; then
    if ! printf '%s' "$json" | jq -e '
      (keys | sort) == ["previous","previous_present","target","version"] and
      (.target | type) == "object" and
      (.previous_present | type) == "boolean" and
      ((.previous_present == false and .previous == null) or
       (.previous_present == true and (.previous | type) == "object"))
    ' >/dev/null 2>&1; then
      echo "Error: malformed proxy transition state: $file" >&2
      return 1
    fi
    PROXY_TRANSITION_TARGET_JSON="$(printf '%s' "$json" | jq -ce '.target')" || return 1
    _proxy_parse_record "$PROXY_TRANSITION_TARGET_JSON" "transition target" || return 1
    PROXY_TRANSITION_TARGET_SERVICE="$PROXY_RECORD_SERVICE"
    PROXY_TRANSITION_TARGET_MODEL="$PROXY_RECORD_MODEL"
    PROXY_TRANSITION_TARGET_LISTEN="$PROXY_RECORD_LISTEN"
    PROXY_TRANSITION_TARGET_RUNTIME_ID="$PROXY_RECORD_RUNTIME_ID"
    PROXY_TRANSITION_TARGET_IDENTITY="$PROXY_RECORD_IDENTITY"
    PROXY_TRANSITION_PREVIOUS_PRESENT="$(printf '%s' "$json" | jq -er '.previous_present | tostring')" || return 1
    if [[ "$PROXY_TRANSITION_PREVIOUS_PRESENT" == "true" ]]; then
      PROXY_TRANSITION_PREVIOUS_JSON="$(printf '%s' "$json" | jq -ce '.previous')" || return 1
      _proxy_parse_record "$PROXY_TRANSITION_PREVIOUS_JSON" "transition previous" || return 1
      PROXY_TRANSITION_PREVIOUS_SERVICE="$PROXY_RECORD_SERVICE"
      PROXY_TRANSITION_PREVIOUS_MODEL="$PROXY_RECORD_MODEL"
      PROXY_TRANSITION_PREVIOUS_LISTEN="$PROXY_RECORD_LISTEN"
      PROXY_TRANSITION_PREVIOUS_RUNTIME_ID="$PROXY_RECORD_RUNTIME_ID"
      PROXY_TRANSITION_PREVIOUS_IDENTITY="$PROXY_RECORD_IDENTITY"
    fi
    PROXY_TRANSITION_VERSION="2"
    return 0
  fi

  if [[ "$version" == "1" ]]; then
    # Recover transition files written by the prior bundle. Their configuration
    # identity is unknowable, so recovery always restarts under the current,
    # explicitly requested configuration before writing a schema-v2 commit.
    if ! printf '%s' "$json" | jq -e '
      (.target | type) == "string" and (.target | length) > 0 and
      (.previous_present | type) == "boolean" and
      (.previous | type) == "string" and
      ((.previous_present == false) or (.previous | length) > 0)
    ' >/dev/null 2>&1; then
      echo "Error: malformed legacy proxy transition state: $file" >&2
      return 1
    fi
    PROXY_TRANSITION_TARGET_MODEL="$(printf '%s' "$json" | jq -er '.target')" || return 1
    PROXY_TRANSITION_PREVIOUS_PRESENT="$(printf '%s' "$json" | jq -er '.previous_present | tostring')" || return 1
    PROXY_TRANSITION_PREVIOUS_MODEL="$(printf '%s' "$json" | jq -er '.previous')" || return 1
    PROXY_TRANSITION_VERSION="1"
    return 0
  fi

  echo "Error: unsupported proxy transition schema: $version" >&2
  return 1
}

_proxy_restart() {
  local service="$1" timeout="${PROXY_RESTART_TIMEOUT_SECONDS:-30}" status=0
  case "$timeout" in ''|*[!0-9]*) timeout=30 ;; esac
  [[ "$timeout" -gt 0 ]] || timeout=30

  if launcher_run_with_timeout "$timeout" 2 flox services restart "$service"; then
    return 0
  else
    status=$?
  fi
  if [[ $status -eq 124 ]]; then
    echo "Error: timed out restarting service $service after ${timeout}s" >&2
  fi
  return 1
}

_proxy_wait_ready() {
  local listen="$1" timeout="${PROXY_READY_TIMEOUT_SECONDS:-10}" deadline=0
  case "$timeout" in ''|*[!0-9]*) timeout=10 ;; esac
  [[ "$timeout" -gt 0 ]] || timeout=10
  deadline=$((SECONDS + timeout))
  while [[ $SECONDS -lt $deadline ]]; do
    _proxy_healthcheck "$listen" && return 0
    sleep 0.1
  done
  return 1
}

# Usage:
#   proxy_ensure_model <service> <model> <health-listen> <config-component>...
#
# Config components must bind every service input not represented by model,
# including normalized upstream URL, all listener URLs, a non-secret credential
# identity, and an explicit protocol/config revision. Their ordered tuple is
# hashed into the committed and transition records.
proxy_ensure_model() (
  local service="$1" model="$2" listen="$3"
  shift 3
  local cache_dir="${FLOX_ENV_CACHE:?FLOX_ENV_CACHE is required}"
  local model_file="${cache_dir}/${service}.model"
  local committed_file="${model_file}.committed"
  local transition_file="${model_file}.transition"
  local lock_file="${model_file}.lock"
  local normalized_listen="" runtime_id="" identity="" requested_record=""
  local component="" desired="" had_committed="false"
  local committed_version="" committed_json="" committed_service="" committed_model=""
  local committed_listen="" committed_runtime_id="" committed_identity=""
  local previous_present="false" previous_record="" previous_model="" previous_runtime_id=""
  local recovery_matches="false"

  [[ $# -ge 1 ]] || {
    echo "Error: proxy configuration identity is required for $service" >&2
    return 1
  }
  _proxy_validate_scalar "$service" "proxy service" || return 1
  _proxy_validate_scalar "$model" "proxy model" || return 1
  normalized_listen="$(_proxy_base_url "$listen")" || return 1
  for component in "$@"; do
    _proxy_validate_scalar "$component" "proxy configuration component" || return 1
  done
  runtime_id="$(launcher_profile_key "proxy-runtime-v2" "$service" "$normalized_listen" "$@")" || return 1
  identity="$(launcher_profile_key "proxy-applied-v2" "$service" "$model" "$runtime_id")" || return 1
  requested_record="$(_proxy_make_record "$service" "$model" "$normalized_listen" "$runtime_id" "$identity")" || return 1

  mkdir -p "$cache_dir" || {
    echo "Error: cannot create proxy cache directory: $cache_dir" >&2
    return 1
  }

  LAUNCHER_LOCK_FILE=""
  LAUNCHER_LOCK_FD=""
  launcher_lock_acquire "$lock_file" 30 120 "$service configuration transition" || return 1
  _proxy_lock_cleanup() {
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
  trap '_proxy_lock_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  if [[ -e "$model_file" || -L "$model_file" ]]; then
    desired="$(_proxy_read_scalar_file "$model_file" "proxy desired model")" || return 1
  fi
  if [[ -e "$committed_file" || -L "$committed_file" ]]; then
    _proxy_read_committed "$committed_file" || return 1
    committed_version="$PROXY_COMMITTED_VERSION"
    committed_json="$PROXY_COMMITTED_JSON"
    committed_service="$PROXY_COMMITTED_SERVICE"
    committed_model="$PROXY_COMMITTED_MODEL"
    committed_listen="$PROXY_COMMITTED_LISTEN"
    committed_runtime_id="$PROXY_COMMITTED_RUNTIME_ID"
    committed_identity="$PROXY_COMMITTED_IDENTITY"
    if [[ "$committed_version" == "2" && "$committed_service" != "$service" ]]; then
      echo "Error: committed proxy state belongs to service $committed_service, not $service" >&2
      return 1
    fi
    had_committed="true"
  fi

  # A durable transition means applied state was never committed. Recovery is
  # permitted only when this invocation's complete identity matches one side of
  # the transaction. This is essential when model names are equal but endpoints,
  # credentials, listeners, or protocol configuration differ.
  if [[ -e "$transition_file" || -L "$transition_file" ]]; then
    _proxy_read_transition "$transition_file" || return 1
    if [[ "$PROXY_TRANSITION_VERSION" == "2" ]]; then
      if [[ "$PROXY_TRANSITION_TARGET_SERVICE" != "$service" \
          || ( "$PROXY_TRANSITION_PREVIOUS_PRESENT" == "true" \
               && "$PROXY_TRANSITION_PREVIOUS_SERVICE" != "$service" ) ]]; then
        echo "Error: proxy transition state belongs to another service" >&2
        return 1
      fi
      if _proxy_record_matches_request \
          "$PROXY_TRANSITION_TARGET_SERVICE" \
          "$PROXY_TRANSITION_TARGET_MODEL" \
          "$PROXY_TRANSITION_TARGET_LISTEN" \
          "$PROXY_TRANSITION_TARGET_RUNTIME_ID" \
          "$PROXY_TRANSITION_TARGET_IDENTITY" \
          "$service" "$model" "$normalized_listen" "$runtime_id" "$identity"; then
        recovery_matches="true"
      elif [[ "$PROXY_TRANSITION_PREVIOUS_PRESENT" == "true" ]] \
          && _proxy_record_matches_request \
            "$PROXY_TRANSITION_PREVIOUS_SERVICE" \
            "$PROXY_TRANSITION_PREVIOUS_MODEL" \
            "$PROXY_TRANSITION_PREVIOUS_LISTEN" \
            "$PROXY_TRANSITION_PREVIOUS_RUNTIME_ID" \
            "$PROXY_TRANSITION_PREVIOUS_IDENTITY" \
            "$service" "$model" "$normalized_listen" "$runtime_id" "$identity"; then
        recovery_matches="true"
      fi
    else
      if [[ "$model" == "$PROXY_TRANSITION_TARGET_MODEL" \
          || ( "$PROXY_TRANSITION_PREVIOUS_PRESENT" == "true" \
               && "$model" == "$PROXY_TRANSITION_PREVIOUS_MODEL" ) ]]; then
        recovery_matches="true"
      fi
    fi

    if [[ "$recovery_matches" != "true" ]]; then
      echo "Error: requested $service configuration matches neither side of its durable transition" >&2
      return 1
    fi
    if [[ -n "$desired" && "$desired" != "$PROXY_TRANSITION_TARGET_MODEL" \
        && ! ( "$PROXY_TRANSITION_PREVIOUS_PRESENT" == "true" \
               && "$desired" == "$PROXY_TRANSITION_PREVIOUS_MODEL" ) ]]; then
      echo "Error: proxy desired state is outside its durable transition" >&2
      return 1
    fi

    _proxy_write_scalar_file "$model_file" "$model" "proxy recovery desired model" || return 1
    if _proxy_restart "$service" && _proxy_wait_ready "$normalized_listen"; then
      _proxy_write_committed "$committed_file" "$requested_record" || return 1
      _proxy_remove_durable "$transition_file" || return 1
      desired="$model"
      committed_version="2"
      committed_json="$requested_record"
      committed_service="$service"
      committed_model="$model"
      committed_listen="$normalized_listen"
      committed_runtime_id="$runtime_id"
      committed_identity="$identity"
      had_committed="true"
    else
      echo "Error: could not recover incomplete $service configuration transition" >&2
      return 1
    fi
  fi

  if [[ "$had_committed" == "true" && "$committed_version" == "2" \
      && "$desired" == "$model" ]] \
      && _proxy_record_matches_request \
        "$committed_service" "$committed_model" "$committed_listen" \
        "$committed_runtime_id" "$committed_identity" \
        "$service" "$model" "$normalized_listen" "$runtime_id" "$identity" \
      && _proxy_healthcheck "$normalized_listen"; then
    return 0
  fi

  if [[ "$had_committed" == "true" && "$committed_version" == "2" ]]; then
    previous_present="true"
    previous_record="$committed_json"
    previous_model="$committed_model"
    previous_runtime_id="$committed_runtime_id"
  fi

  _proxy_write_transition "$transition_file" "$requested_record" "$previous_present" "$previous_record" || {
    echo "Error: cannot begin $service configuration transition" >&2
    return 1
  }
  _proxy_write_scalar_file "$model_file" "$model" "proxy desired model" || return 1

  if _proxy_restart "$service" && _proxy_wait_ready "$normalized_listen"; then
    _proxy_write_committed "$committed_file" "$requested_record" || return 1
    _proxy_remove_durable "$transition_file" || return 1
    return 0
  fi

  # A rollback can be executed by this process only when all runtime service
  # configuration except the model is unchanged. Otherwise the current process
  # cannot truthfully recreate the previous endpoint/credential environment;
  # retain the transition and fail closed for a later invocation matching one
  # of its recorded identities.
  if [[ "$previous_present" == "true" \
      && "$committed_service" == "$service" \
      && "$committed_listen" == "$normalized_listen" \
      && "$previous_runtime_id" == "$runtime_id" ]]; then
    if _proxy_write_scalar_file "$model_file" "$previous_model" "proxy rollback desired model" \
        && _proxy_restart "$service" && _proxy_wait_ready "$normalized_listen" \
        && _proxy_write_committed "$committed_file" "$previous_record" \
        && _proxy_remove_durable "$transition_file"; then
      echo "Error: could not switch $service to $model; previous model $previous_model was restored" >&2
      return 1
    fi
    echo "Error: could not switch $service to $model, and rollback to $previous_model was incomplete" >&2
    return 1
  fi

  if [[ "$previous_present" == "true" ]]; then
    echo "Error: could not apply $service configuration; automatic rollback is unsafe because its runtime identity changed" >&2
    echo "  Durable transition retained for recovery by a matching configuration." >&2
    return 1
  fi

  echo "Error: could not apply $service configuration; no complete previously committed identity was available" >&2
  return 1
)
