# Shared helper — sourced by launch-* omlx wrappers.
# Ensures a model is loaded in omlx, downloading from HuggingFace if missing.
# Sets OMLX_API_KEY on success.

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

# Resolves a HuggingFace token via (in order):
#   1. macOS keychain
#   2. ~/.cache/huggingface/token (HF CLI standard location)
#   3. Interactive gum prompt (TTY only); saves result for future runs
# Outputs the token to stdout. Returns 1 on failure.
_hf_token_get() {
  local model="${1:-model}"
  local token=""

  token="$(_hf_token_from_keychain)" || true

  if [[ -z "$token" && -f "$HOME/.cache/huggingface/token" ]]; then
    token="$(<"$HOME/.cache/huggingface/token")"
  fi

  if [[ -z "$token" ]]; then
    if [[ ! -t 2 ]]; then
      echo "Error: HuggingFace token required to download '${model}'." >&2
      echo "  Run this command in an interactive terminal, or populate ~/.cache/huggingface/token" >&2
      return 1
    fi
    if command -v gum &>/dev/null; then
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
    mkdir -p "$HOME/.cache/huggingface"
    printf '%s' "$token" > "$HOME/.cache/huggingface/token"
    chmod 600 "$HOME/.cache/huggingface/token"
  fi

  printf '%s' "$token"
}

# --- omlx API key helpers ---

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
  local key="$1" host="$2" port="$3"
  curl -sf --connect-timeout 3 --max-time 5 \
    -H "Authorization: Bearer $key" \
    "http://${host}:${port}/v1/models" >/dev/null 2>&1
}

# Resolves the omlx API key matching the running omlx instance via:
#   1. macOS keychain (verified against running omlx)
#   2. $FLOX_ENV_CACHE/omlx.api-key (verified; saves to keychain on success)
#   3. find under $HOME/dev and $HOME/.local/share/flox (verified; saves to
#      keychain and $FLOX_ENV_CACHE on success for fast future lookups)
# Outputs the key to stdout. Returns 1 if no valid key found.
_omlx_key_get() {
  local host="$1" port="$2"
  local key="" candidate=""

  # 1. Keychain
  key="$(_omlx_key_from_keychain)" || true
  if [[ -n "$key" ]] && _omlx_key_verify "$key" "$host" "$port"; then
    printf '%s' "$key"; return 0
  fi

  # 2. Current env cache
  if [[ -s "${FLOX_ENV_CACHE:-}/omlx.api-key" ]]; then
    candidate="$(<"${FLOX_ENV_CACHE}/omlx.api-key")"
    if _omlx_key_verify "$candidate" "$host" "$port"; then
      _omlx_key_save_keychain "$candidate" || true
      printf '%s' "$candidate"; return 0
    fi
  fi

  # 3. flox-labs/omlx remote env cache (canonical), then broader flox cache tree
  local f
  while IFS= read -r f; do
    [[ -s "$f" ]] || continue
    candidate="$(<"$f")"
    [[ -z "$candidate" ]] && continue
    if _omlx_key_verify "$candidate" "$host" "$port"; then
      _omlx_key_save_keychain "$candidate" || true
      [[ -n "${FLOX_ENV_CACHE:-}" ]] && printf '%s' "$candidate" > "${FLOX_ENV_CACHE}/omlx.api-key"
      printf '%s' "$candidate"; return 0
    fi
  done < <(find "$HOME/.cache/flox/remote" \
    -name "omlx.api-key" -maxdepth 4 2>/dev/null)

  echo "Error: could not find a valid omlx API key for ${host}:${port}" >&2
  echo "  Is omlx running? Try: flox services status  (start with: flox activate -s)" >&2
  return 1
}

omlx_ensure_model() {
  local model="$1" host="$2" port="$3"
  local base="http://${host}:${port}"

  OMLX_API_KEY="$(_omlx_key_get "$host" "$port")" || return 1

  local models
  if ! models="$(curl -sf --connect-timeout 5 --max-time 10 \
      -H "Authorization: Bearer $OMLX_API_KEY" \
      "$base/v1/models" 2>/dev/null)"; then
    echo "Error: cannot reach omlx at ${host}:${port}" >&2
    echo "  Is omlx running? Try: flox services status" >&2
    return 1
  fi

  # omlx strips org prefix in /v1/models listings; check both full and short name
  local short_name="${model##*/}"
  if echo "$models" | jq -e --arg m "$model" --arg s "$short_name" \
      '.data[] | select(.id == $m or .id == $s)' >/dev/null 2>&1; then
    return 0
  fi

  local hf_token
  hf_token="$(_hf_token_get "$model")" || return 1

  # Admin login (cookie-based session)
  local cookies
  cookies="$(mktemp -t omlx-cookies.XXXXXX)"
  # Clean up cookie file if the script is interrupted during the download poll.
  # Normal exit paths use explicit rm -f; this trap covers SIGINT/TERM/HUP.
  # The calling script's trap (set after this function returns) will overwrite this.
  trap 'rm -f "${cookies:-}"' INT TERM HUP
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    -c "$cookies" \
    -X POST "$base/admin/api/login" \
    -H 'Content-Type: application/json' \
    -d "{\"api_key\":\"$OMLX_API_KEY\"}")"
  if [[ "$status" != "200" ]]; then
    rm -f "$cookies"
    echo "Error: omlx admin login failed (HTTP $status)" >&2
    echo "  Try: flox services restart omlx" >&2
    return 1
  fi

  # Escape model/token for JSON
  local model_json="${model//\\/\\\\}"
  model_json="${model_json//\"/\\\"}"
  local hf_json="${hf_token//\\/\\\\}"
  hf_json="${hf_json//\"/\\\"}"

  # Trigger download
  echo "Downloading ${model}..." >&2
  local resp task_id
  if ! resp="$(curl -fsS --connect-timeout 5 --max-time 30 \
      -b "$cookies" \
      -X POST "$base/admin/api/hf/download" \
      -H 'Content-Type: application/json' \
      -d "{\"repo_id\":\"${model_json}\",\"hf_token\":\"${hf_json}\"}" 2>&1)"; then
    rm -f "$cookies"
    echo "Error: failed to start download for ${model}" >&2
    return 1
  fi
  task_id="$(echo "$resp" | jq -r '.task.task_id // empty')"
  if [[ -z "$task_id" ]]; then
    rm -f "$cookies"
    echo "Error: download did not start for ${model}: $resp" >&2
    return 1
  fi

  # Poll until complete (900 * 2s = 30 min cap)
  local state="" n=0 prog task
  while true; do
    n=$((n + 1))
    if [[ $n -gt 900 ]]; then
      rm -f "$cookies"
      printf '\n' >&2
      echo "Error: download timed out after 30 min (last state: ${state:-?})" >&2
      return 1
    fi
    task="$(curl -fsS -b "$cookies" "$base/admin/api/hf/tasks" 2>/dev/null \
      | jq -c --arg id "$task_id" '.tasks[] | select(.task_id == $id)')"
    state="$(echo "$task" | jq -r '.status')"
    case "$state" in
      completed)
        printf '\r\033[K' >&2
        echo "done." >&2
        break
        ;;
      failed)
        rm -f "$cookies"
        printf '\n' >&2
        echo "Error: download failed: $(echo "$task" | jq -r '.error')" >&2
        return 1
        ;;
      *)
        prog="$(echo "$task" | jq -r '.progress')"
        printf '\r  %s  %.1f%%' "${state:-?}" "${prog:-0}" >&2
        sleep 2
        ;;
    esac
  done
  rm -f "$cookies"
}
