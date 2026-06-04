# Shared helper — sourced by launch scripts that use llamacpp-proxy services.
# Writes the desired model to a state file and restarts the service if the
# model changed or the service is not healthy.
#
# Usage: proxy_ensure_model <service-name> <model> <listen-addr>
#   <listen-addr> is the --listen (OpenAI) address, used for health check.

proxy_ensure_model() {
  local service="$1" model="$2" listen="$3"
  local model_file="${FLOX_ENV_CACHE}/${service}.model"
  local current; current="$(cat "$model_file" 2>/dev/null || true)"

  local healthy=false
  curl -sf --connect-timeout 1 --max-time 2 \
    "http://${listen}/health" >/dev/null 2>&1 && healthy=true

  if [[ "$current" != "$model" ]] || [[ "$healthy" != "true" ]]; then
    printf '%s' "$model" > "$model_file"
    flox services restart "$service" || {
      echo "Error: could not restart service $service" >&2
      return 1
    }
    local ready=false
    for _ in $(seq 1 50); do
      if curl -sf --connect-timeout 1 --max-time 2 \
          "http://${listen}/health" >/dev/null 2>&1; then
        ready=true; break
      fi
      sleep 0.1
    done
    if [[ "$ready" != "true" ]]; then
      echo "Error: $service did not become ready in time" >&2
      return 1
    fi
  fi
}
