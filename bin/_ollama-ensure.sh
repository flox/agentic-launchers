# Shared helper — sourced by launch-* wrappers.

# Normalize OLLAMA_HOST which may already contain a port (ollama convention).
# After calling: OLLAMA_HOST is host-only, OLLAMA_PORT is port-only.
ollama_normalize_host_port() {
  if [[ "${OLLAMA_HOST:-}" == *:* ]]; then
    OLLAMA_PORT="${OLLAMA_HOST##*:}"
    OLLAMA_HOST="${OLLAMA_HOST%:*}"
  fi
  OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1}"
  OLLAMA_PORT="${OLLAMA_PORT:-11434}"
}

# Ensures a model exists locally in ollama, pulling it if missing.
ollama_ensure_model() {
  local model="$1" host="$2" port="$3"
  local normalized="$model"
  if [[ "$model" != *:* ]]; then
    normalized="${model}:latest"
  fi

  local tags
  if ! tags="$(curl -sf --connect-timeout 5 --max-time 10 "http://${host}:${port}/api/tags")"; then
    echo "Error: cannot reach ollama at ${host}:${port}" >&2
    return 1
  fi

  if echo "$tags" | grep -qF "\"name\":\"${normalized}\","; then
    return 0
  fi

  echo "Pulling ${normalized}..." >&2
  local model_escaped="${model//\\/\\\\}"
  model_escaped="${model_escaped//\"/\\\"}"
  local pull_output
  pull_output="$(curl -s --connect-timeout 5 --max-time 600 "http://${host}:${port}/api/pull" -d "{\"name\":\"${model_escaped}\"}")"

  if echo "$pull_output" | grep -qF '"status":"success"'; then
    echo "done." >&2
    return 0
  fi

  local err
  err="$(echo "$pull_output" | grep '"error"' | tail -1 || true)"
  echo "Error: failed to pull ${normalized}: ${err}" >&2
  return 1
}
