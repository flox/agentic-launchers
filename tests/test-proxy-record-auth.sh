#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
TMP="$(mktemp -d -t proxy-record-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

PASS=0
pass() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || { printf 'expected <%s>, got <%s>\n' "$1" "$2" >&2; fail "$3"; }; }
assert_contains() { [[ "$1" == *"$2"* ]] || { printf 'missing <%s> in <%s>\n' "$2" "$1" >&2; fail "$3"; }; }

BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/sync" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$BIN/flox" <<'SH'
#!/usr/bin/env bash
printf 'restart\n' >> "$PROXY_TEST_LOG"
SH
chmod 755 "$BIN"/*

runtime="$(bash -c 'source "$1"; launcher_profile_key proxy-runtime-v2 proxy http://127.0.0.1:8081 backend=test' _ "$ROOT/bin/_launcher-common.sh")"
alpha_identity="$(bash -c 'source "$1"; launcher_profile_key proxy-applied-v2 proxy alpha "$2"' _ "$ROOT/bin/_launcher-common.sh" "$runtime")"
other_runtime="$(bash -c 'source "$1"; launcher_profile_key proxy-runtime-v2 other-service http://127.0.0.1:8081 backend=test' _ "$ROOT/bin/_launcher-common.sh")"
other_identity="$(bash -c 'source "$1"; launcher_profile_key proxy-applied-v2 other-service alpha "$2"' _ "$ROOT/bin/_launcher-common.sh" "$other_runtime")"

invoke_proxy() {
  local cache="$1" out="$2" err="$3"
  set +e
  FLOX_ENV_CACHE="$cache" PROXY_TEST_LOG="$PROXY_TEST_LOG" \
    PROXY_RESTART_TIMEOUT_SECONDS=2 PROXY_READY_TIMEOUT_SECONDS=2 \
    PATH="$BIN:/usr/bin:/bin" \
    bash -c 'source "$1"; proxy_ensure_model proxy alpha 127.0.0.1:8081 backend=test' _ \
      "$ROOT/bin/_proxy-ensure.sh" >"$out" 2>"$err"
  INVOKE_STATUS=$?
  set -e
}

new_case() {
  CASE_DIR="$TMP/$1"
  PROXY_TEST_LOG="$TMP/$1.log"
  mkdir -p "$CASE_DIR"
  : > "$PROXY_TEST_LOG"
  printf '%s' alpha > "$CASE_DIR/proxy.model"
}

# 1. Model and digest must describe the same applied identity.
new_case committed-model
jq -cn --arg runtime "$runtime" --arg identity "$alpha_identity" \
  '{version:2,service:"proxy",model:"beta",listen:"http://127.0.0.1:8081",runtime_id:$runtime,identity:$identity}' \
  > "$CASE_DIR/proxy.model.committed"
invoke_proxy "$CASE_DIR" "$TMP/1.out" "$TMP/1.err"
assert_eq 1 "$INVOKE_STATUS" "committed model/digest mismatch"
assert_contains "$(cat "$TMP/1.err")" 'internally inconsistent committed proxy state' "committed model diagnostic"
[[ ! -s "$PROXY_TEST_LOG" ]] || fail "corrupt committed model restarted"
pass "committed model/digest mismatch fails closed"

# 2. Service is digest-bound and also bound to the service-keyed pathname.
new_case committed-service
jq -cn --arg runtime "$runtime" --arg identity "$alpha_identity" \
  '{version:2,service:"other-service",model:"alpha",listen:"http://127.0.0.1:8081",runtime_id:$runtime,identity:$identity}' \
  > "$CASE_DIR/proxy.model.committed"
invoke_proxy "$CASE_DIR" "$TMP/2a.out" "$TMP/2a.err"
assert_eq 1 "$INVOKE_STATUS" "committed service/digest mismatch"
assert_contains "$(cat "$TMP/2a.err")" 'internally inconsistent committed proxy state' "committed service diagnostic"
jq -cn --arg runtime "$other_runtime" --arg identity "$other_identity" \
  '{version:2,service:"other-service",model:"alpha",listen:"http://127.0.0.1:8081",runtime_id:$runtime,identity:$identity}' \
  > "$CASE_DIR/proxy.model.committed"
invoke_proxy "$CASE_DIR" "$TMP/2b.out" "$TMP/2b.err"
assert_eq 1 "$INVOKE_STATUS" "foreign-service committed record"
assert_contains "$(cat "$TMP/2b.err")" 'belongs to service other-service' "foreign service path binding"
[[ ! -s "$PROXY_TEST_LOG" ]] || fail "foreign service record restarted"
pass "committed service is digest-bound and path-bound"

# 3. Transition target records must be internally consistent.
new_case transition-target
jq -cn --arg runtime "$runtime" --arg identity "$alpha_identity" \
  '{version:2,target:{version:2,service:"proxy",model:"beta",listen:"http://127.0.0.1:8081",runtime_id:$runtime,identity:$identity},previous_present:false,previous:null}' \
  > "$CASE_DIR/proxy.model.transition"
invoke_proxy "$CASE_DIR" "$TMP/3.out" "$TMP/3.err"
assert_eq 1 "$INVOKE_STATUS" "transition target mismatch"
assert_contains "$(cat "$TMP/3.err")" 'internally inconsistent transition target proxy state' "target diagnostic"
pass "transition target identity is recomputed"

# 4. Transition previous records receive the same validation.
new_case transition-previous
jq -cn --arg runtime "$runtime" --arg identity "$alpha_identity" \
  '{version:2,target:{version:2,service:"proxy",model:"alpha",listen:"http://127.0.0.1:8081",runtime_id:$runtime,identity:$identity},previous_present:true,previous:{version:2,service:"proxy",model:"beta",listen:"http://127.0.0.1:8081",runtime_id:$runtime,identity:$identity}}' \
  > "$CASE_DIR/proxy.model.transition"
invoke_proxy "$CASE_DIR" "$TMP/4.out" "$TMP/4.err"
assert_eq 1 "$INVOKE_STATUS" "transition previous mismatch"
assert_contains "$(cat "$TMP/4.err")" 'internally inconsistent transition previous proxy state' "previous diagnostic"
pass "transition previous identity is recomputed"

# 5. A digest-consistent commit still must match every current request field.
new_case committed-listener
jq -cn --arg runtime "$runtime" --arg identity "$alpha_identity" \
  '{version:2,service:"proxy",model:"alpha",listen:"http://other-listener:8081",runtime_id:$runtime,identity:$identity}' \
  > "$CASE_DIR/proxy.model.committed"
invoke_proxy "$CASE_DIR" "$TMP/5.out" "$TMP/5.err"
assert_eq 0 "$INVOKE_STATUS" "listener-mismatched commit recovery"
assert_eq restart "$(cat "$PROXY_TEST_LOG")" "listener mismatch forces restart"
assert_eq http://127.0.0.1:8081 "$(jq -r .listen "$CASE_DIR/proxy.model.committed")" "corrected listener committed"
pass "committed fast path compares the complete tuple"

# 6. Transition recovery also compares every tuple field, not the digest alone.
new_case transition-listener
jq -cn --arg runtime "$runtime" --arg identity "$alpha_identity" \
  '{version:2,target:{version:2,service:"proxy",model:"alpha",listen:"http://other-listener:8081",runtime_id:$runtime,identity:$identity},previous_present:false,previous:null}' \
  > "$CASE_DIR/proxy.model.transition"
invoke_proxy "$CASE_DIR" "$TMP/6.out" "$TMP/6.err"
assert_eq 1 "$INVOKE_STATUS" "transition listener mismatch"
assert_contains "$(cat "$TMP/6.err")" 'matches neither side' "transition tuple diagnostic"
[[ ! -s "$PROXY_TEST_LOG" ]] || fail "mismatched transition restarted"
pass "transition recovery compares complete tuples"

# 7. Schema hashes use one portable canonical spelling.
new_case uppercase-hash
upper_runtime="$(printf '%s' "$runtime" | tr '[:lower:]' '[:upper:]')"
upper_identity="$(printf '%s' "$alpha_identity" | tr '[:lower:]' '[:upper:]')"
jq -cn --arg runtime "$upper_runtime" --arg identity "$upper_identity" \
  '{version:2,service:"proxy",model:"alpha",listen:"http://127.0.0.1:8081",runtime_id:$runtime,identity:$identity}' \
  > "$CASE_DIR/proxy.model.committed"
invoke_proxy "$CASE_DIR" "$TMP/7.out" "$TMP/7.err"
assert_eq 1 "$INVOKE_STATUS" "uppercase hash record"
assert_contains "$(cat "$TMP/7.err")" 'malformed committed proxy state' "lowercase schema diagnostic"
pass "schema-v2 hashes are canonical lowercase SHA-256"

printf '1..%d\n' "$PASS"
