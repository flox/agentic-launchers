# Shared correctness, publication, identity, locking, and timeout helpers.

# Return a collision-resistant, filesystem-safe key over an ordered tuple.
# Every argument is length-delimited by a NUL byte before hashing, so distinct
# tuples cannot become ambiguous through string concatenation.
launcher_profile_key() {
  local output digest value
  [[ $# -ge 1 ]] || return 1

  if command -v sha256sum >/dev/null 2>&1; then
    output="$({ for value in "$@"; do printf '%s\0' "$value"; done; } | sha256sum)" || return 1
    digest="${output%% *}"
  elif command -v shasum >/dev/null 2>&1; then
    output="$({ for value in "$@"; do printf '%s\0' "$value"; done; } | shasum -a 256)" || return 1
    digest="${output%% *}"
  elif command -v openssl >/dev/null 2>&1; then
    output="$({ for value in "$@"; do printf '%s\0' "$value"; done; } | openssl dgst -sha256)" || return 1
    digest="${output##* }"
  else
    echo "Error: SHA-256 utility required (sha256sum, shasum, or openssl)" >&2
    return 1
  fi

  case "$digest" in
    ''|*[!0-9a-fA-F]*) return 1 ;;
  esac
  [[ ${#digest} -eq 64 ]] || return 1
  printf '%s' "$digest"
}

_launcher_validate_regular_target() {
  local target="$1"
  if [[ -e "$target" || -L "$target" ]]; then
    if [[ -L "$target" || ! -f "$target" ]]; then
      echo "Error: refusing non-regular config target: $target" >&2
      return 1
    fi
  fi
}

# Flush pending filesystem writes. POSIX sync has intentionally global scope;
# callers should reserve this for state transitions whose ordering must survive
# abrupt process or machine failure.
launcher_sync_filesystem() {
  if ! command -v sync >/dev/null 2>&1; then
    echo "Error: sync utility is required for durable state publication" >&2
    return 1
  fi
  sync
}

# Atomically replace a regular file with stdin content. The packaged native
# helper invokes rename(2) directly while retaining an open source descriptor,
# then binds success to the exact inode published at the requested path. This
# avoids command-line mv's "move into directory" semantics and its associated
# destination-substitution race.
#
# Usage: launcher_atomic_write_file <target> [mode] [durable]
#   durable=true additionally syncs the filesystem after verified publication.
launcher_atomic_write_file() (
  local target="$1" mode="${2:-600}" durable="${3:-false}"
  local dir tmp="" write_lock="" helper=""

  dir="${target%/*}"
  [[ "$dir" != "$target" ]] || dir="."
  mkdir -p "$dir" || return 1

  LAUNCHER_LOCK_FILE=""
  LAUNCHER_LOCK_FD=""
  write_lock="${target}.write.lock"
  launcher_lock_acquire "$write_lock" 30 120 "publication for $target" || return 1

  _launcher_atomic_cleanup() {
    local cleanup_status=$? release_status=0
    if [[ -n "$tmp" ]] && ! rm -f "$tmp"; then
      echo "Error: could not remove unpublished temporary: $tmp" >&2
      [[ $cleanup_status -ne 0 ]] || cleanup_status=1
    fi
    if launcher_lock_release; then
      :
    else
      release_status=$?
      [[ $cleanup_status -ne 0 ]] || cleanup_status=$release_status
    fi
    trap - EXIT
    exit "$cleanup_status"
  }
  trap '_launcher_atomic_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  tmp="$(mktemp "${target}.tmp.XXXXXX")" || return 1
  chmod "$mode" "$tmp" || return 1
  cat > "$tmp" || return 1

  helper="$(_launcher_lock_helper_path)" || return 1
  if ! "$helper" replace-file "$tmp" "$target"; then
    echo "Error: atomic publication failed for $target" >&2
    return 1
  fi
  tmp=""

  if [[ "$durable" == "true" ]]; then
    launcher_sync_filesystem || return 1
  fi
)

# Change a regular file's mode through a retained hard link and verify that the
# requested path still names that inode. This avoids a validate-then-chmod
# symlink substitution window when an existing credential file is reused.
_launcher_chmod_verified_regular() (
  local target="$1" mode="$2" guard=""
  _launcher_validate_regular_target "$target" || return 1
  guard="$(mktemp "${target}.chmod.XXXXXX")" || return 1
  rm -f "$guard" || return 1
  trap '[[ -z "$guard" ]] || rm -f "$guard"' EXIT INT TERM HUP
  ln "$target" "$guard" || return 1
  if [[ -L "$guard" || ! -f "$guard" || -L "$target" || ! -f "$target" \
      || ! "$target" -ef "$guard" ]]; then
    echo "Error: credential target changed during validation: $target" >&2
    return 1
  fi
  chmod "$mode" "$guard" || return 1
  if [[ -L "$target" || ! -f "$target" || ! "$target" -ef "$guard" ]]; then
    echo "Error: credential target changed during mode update: $target" >&2
    return 1
  fi
)

# Publish stdin content only when the destination does not already exist.
# A per-target lock serializes local publishers, a same-directory hard link
# provides atomic no-clobber publication, and inode postconditions bind success
# to the requested path.
launcher_write_file_if_absent() (
  local target="$1" mode="${2:-600}" durable="${3:-false}"
  local dir tmp="" write_lock=""

  dir="${target%/*}"
  [[ "$dir" != "$target" ]] || dir="."
  mkdir -p "$dir" || return 1

  LAUNCHER_LOCK_FILE=""
  LAUNCHER_LOCK_FD=""
  write_lock="${target}.write.lock"
  launcher_lock_acquire "$write_lock" 30 120 "publication for $target" || return 1

  _launcher_create_cleanup() {
    local cleanup_status=$? release_status=0
    if [[ -n "$tmp" ]] && ! rm -f "$tmp"; then
      echo "Error: could not remove unpublished temporary: $tmp" >&2
      [[ $cleanup_status -ne 0 ]] || cleanup_status=1
    fi
    if launcher_lock_release; then
      :
    else
      release_status=$?
      [[ $cleanup_status -ne 0 ]] || cleanup_status=$release_status
    fi
    trap - EXIT
    exit "$cleanup_status"
  }
  trap '_launcher_create_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  if [[ -e "$target" || -L "$target" ]]; then
    _launcher_chmod_verified_regular "$target" "$mode" || return 1
    return 0
  fi

  tmp="$(mktemp "${target}.tmp.XXXXXX")" || return 1
  chmod "$mode" "$tmp" || return 1
  cat > "$tmp" || return 1

  if ln "$tmp" "$target" 2>/dev/null; then
    if [[ -L "$target" || ! -f "$target" || ! "$target" -ef "$tmp" ]]; then
      echo "Error: publication postcondition failed for $target" >&2
      return 1
    fi
    if [[ "$durable" == "true" ]]; then
      launcher_sync_filesystem || return 1
    fi
    return 0
  fi

  if [[ -e "$target" || -L "$target" ]]; then
    _launcher_chmod_verified_regular "$target" "$mode" || return 1
    return 0
  fi

  echo "Error: could not publish $target" >&2
  return 1
)

_launcher_lock_helper_path() {
  local helper_dir="" kernel="" machine="" suffix="" helper=""

  case "${BASH_SOURCE[0]}" in
    */*) helper_dir="${BASH_SOURCE[0]%/*}" ;;
    *) helper_dir="." ;;
  esac
  helper_dir="$(cd -- "$helper_dir" && pwd -P)" || return 1
  kernel="$(uname -s 2>/dev/null)" || return 1
  machine="$(uname -m 2>/dev/null)" || return 1

  case "$kernel:$machine" in
    Linux:x86_64|Linux:amd64) suffix="linux-amd64" ;;
    Linux:aarch64|Linux:arm64) suffix="linux-arm64" ;;
    Darwin:x86_64|Darwin:amd64) suffix="darwin-amd64" ;;
    Darwin:arm64|Darwin:aarch64) suffix="darwin-arm64" ;;
    *)
      echo "Error: unsupported platform for launcher kernel locks: $kernel/$machine" >&2
      return 1
      ;;
  esac

  helper="$helper_dir/_launcher-lock-helper-$suffix"
  if [[ ! -f "$helper" || ! -x "$helper" ]]; then
    echo "Error: missing launcher kernel-lock helper: $helper" >&2
    return 1
  fi
  printf '%s' "$helper"
}

_launcher_fd_is_open() {
  local fd="$1"
  if eval ": <&$fd" 2>/dev/null; then
    return 0
  fi
  if eval ": >&$fd" 2>/dev/null; then
    return 0
  fi
  return 1
}

_launcher_find_free_fd() {
  local fd=""
  for fd in 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    if ! _launcher_fd_is_open "$fd"; then
      printf '%s' "$fd"
      return 0
    fi
  done
  echo "Error: no free file descriptor is available for a launcher lock" >&2
  return 1
}

# Acquire a kernel-managed advisory lock on a persistent regular file. A tiny
# native helper applies flock(2) to an inherited descriptor and exits; the Bash
# owner retains the same open-file description, so the kernel releases authority
# automatically when the owner and any still-running protected children close it.
#
# The lock pathname is never reclaimed or unlinked. That removes stale-owner,
# heartbeat, validate-then-unlink, and release-unlink races entirely. The third
# argument is retained for source compatibility with the former lease API.
# Globals set on success: LAUNCHER_LOCK_FILE and LAUNCHER_LOCK_FD.
launcher_lock_acquire() {
  local lock_file="$1" wait_seconds="$2" _stale_after="$3" label="$4"
  local dir="" helper="" fd="" status=0

  case "$wait_seconds" in
    ''|*[!0-9]*)
      echo "Error: invalid wait time for $label lock" >&2
      return 1
      ;;
  esac
  : "$_stale_after"

  if [[ -n "${LAUNCHER_LOCK_FD:-}" ]]; then
    echo "Error: attempted to replace an already-held launcher lock" >&2
    return 1
  fi

  dir="${lock_file%/*}"
  [[ "$dir" != "$lock_file" ]] || dir="."
  mkdir -p "$dir" || {
    echo "Error: cannot create directory for $label lock: $dir" >&2
    return 1
  }

  helper="$(_launcher_lock_helper_path)" || return 1
  fd="$(_launcher_find_free_fd)" || return 1

  # Avoid blocking on known FIFOs/devices before the native descriptor check.
  # The helper repeats the regular-file, no-symlink, and inode checks after the
  # open, closing the cooperative create/open race without path reclamation.
  if [[ -e "$lock_file" || -L "$lock_file" ]]; then
    if [[ -L "$lock_file" || ! -f "$lock_file" ]]; then
      echo "Error: refusing non-regular $label lock object: $lock_file" >&2
      return 1
    fi
  fi

  # Read/write mode creates the persistent inode without truncation and, unlike
  # a write-only FIFO open, cannot block waiting for a peer if a hostile actor
  # swaps the pathname after the precheck. The native helper then rejects any
  # non-regular descriptor and verifies that it still names the requested path.
  if ! eval "exec ${fd}<>\"\$lock_file\""; then
    echo "Error: cannot open $label lock object: $lock_file" >&2
    return 1
  fi

  if "$helper" acquire-fd "$fd" "$lock_file" "$wait_seconds"; then
    status=0
  else
    status=$?
    eval "exec ${fd}>&-" || true
    case "$status" in
      75) echo "Error: timed out waiting for $label lock" >&2 ;;
      76) echo "Error: $label lock owner exited during acquisition" >&2 ;;
      *) echo "Error: could not acquire $label lock" >&2 ;;
    esac
    return 1
  fi

  LAUNCHER_LOCK_FILE="$lock_file"
  LAUNCHER_LOCK_FD="$fd"
}

launcher_lock_release() {
  local fd="${LAUNCHER_LOCK_FD:-}"

  [[ -n "$fd" ]] || return 0
  case "$fd" in
    *[!0-9]*)
      echo "Error: invalid retained launcher lock descriptor: $fd" >&2
      return 1
      ;;
  esac
  if ! _launcher_fd_is_open "$fd"; then
    echo "Error: retained launcher lock descriptor $fd is no longer open" >&2
    return 1
  fi
  if ! eval "exec ${fd}>&-"; then
    echo "Error: could not close launcher lock descriptor $fd" >&2
    return 1
  fi

  LAUNCHER_LOCK_FILE=""
  LAUNCHER_LOCK_FD=""
  return 0
}

# Print all descendants of a process in leaf-first order. This is a best-effort
# portable process-tree snapshot for platforms without a guaranteed setsid(1).
# The direct process is still terminated if ps/awk cannot enumerate children.
_launcher_descendant_pids() {
  local root_pid="$1"
  ps -ax -o pid= -o ppid= 2>/dev/null | awk -v root="$root_pid" '
    {
      pid = $1
      parent = $2
      if (pid ~ /^[0-9]+$/ && parent ~ /^[0-9]+$/) {
        children[parent] = children[parent] " " pid
      }
    }
    function emit(parent, entries, count, i, child) {
      entries = children[parent]
      count = split(entries, ids, " ")
      for (i = 1; i <= count; i++) {
        child = ids[i]
        if (child != "") {
          emit(child)
          print child
        }
      }
    }
    END { emit(root) }
  '
}

# Signal descendants only and return success when at least one valid descendant
# was observed. Leaving the worker shell alive during the graceful phase lets it
# reap the command and publish its completion marker instead of orphaning a
# zombie. The worker itself is signalled when there are no descendants or when
# the grace period expires.
_launcher_signal_descendants() {
  local root_pid="$1" signal="$2" descendants="" pid="" found="false"
  case "$root_pid" in ''|*[!0-9]*) return 1 ;; esac
  [[ "$root_pid" -gt 1 ]] || return 1

  descendants="$(_launcher_descendant_pids "$root_pid" 2>/dev/null || true)"
  for pid in $descendants; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [[ "$pid" -gt 1 ]] || continue
    found="true"
    kill "-$signal" "$pid" 2>/dev/null || true
  done
  [[ "$found" == "true" ]]
}

_launcher_signal_process_tree() {
  local root_pid="$1" signal="$2"
  _launcher_signal_descendants "$root_pid" "$signal" || true
  kill "-$signal" "$root_pid" 2>/dev/null || true
}

# Run a command with a bounded wall-clock deadline. Returns 124 on timeout and
# otherwise preserves the command's exit status and output streams. A private
# completion marker is used instead of kill -0: an exited-but-unreaped child can
# remain visible to kill -0 as a zombie and would otherwise spuriously run to
# the deadline.
launcher_run_with_timeout() (
  local timeout="$1" grace="$2"
  shift 2
  local command_pid="" status=0 deadline=0 grace_deadline=0 timed_out="false"
  local completion_dir="" status_file="" done_file=""

  case "$timeout" in ''|*[!0-9]*) return 2 ;; esac
  case "$grace" in ''|*[!0-9]*) return 2 ;; esac
  [[ "$timeout" -gt 0 ]] || return 2

  completion_dir="$(mktemp -d "${TMPDIR:-/tmp}/launcher-timeout.XXXXXX")" || return 1
  status_file="${completion_dir}/status"
  done_file="${completion_dir}/done"

  _launcher_timeout_cleanup() {
    if [[ -n "$command_pid" ]] && kill -0 "$command_pid" 2>/dev/null; then
      if ! _launcher_signal_descendants "$command_pid" TERM; then
        kill -TERM "$command_pid" 2>/dev/null || true
      fi
      sleep 0.1
      _launcher_signal_process_tree "$command_pid" KILL
      wait "$command_pid" 2>/dev/null || true
    fi
    rm -rf "$completion_dir"
  }
  trap '_launcher_timeout_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  (
    set +e
    "$@"
    child_status=$?
    printf '%s\n' "$child_status" > "$status_file" || exit 125
    : > "$done_file" || exit 125
    exit "$child_status"
  ) &
  command_pid=$!
  deadline=$((SECONDS + timeout))

  while [[ ! -e "$done_file" ]]; do
    if [[ $SECONDS -ge $deadline ]]; then
      timed_out="true"
      if ! _launcher_signal_descendants "$command_pid" TERM; then
        kill -TERM "$command_pid" 2>/dev/null || true
      fi
      grace_deadline=$((SECONDS + grace))
      while [[ ! -e "$done_file" ]] && kill -0 "$command_pid" 2>/dev/null \
          && [[ $SECONDS -lt $grace_deadline ]]; do
        sleep 0.1
      done
      if [[ ! -e "$done_file" ]] && kill -0 "$command_pid" 2>/dev/null; then
        _launcher_signal_process_tree "$command_pid" KILL
      fi
      break
    fi
    sleep 0.05
  done

  if wait "$command_pid"; then
    status=0
  else
    status=$?
  fi
  command_pid=""

  if [[ "$timed_out" == "true" ]]; then
    return 124
  fi
  if [[ ! -f "$status_file" ]]; then
    return "$status"
  fi
  status="$(cat "$status_file")" || return 1
  case "$status" in ''|*[!0-9]*) return 1 ;; esac
  [[ "$status" -le 255 ]] || return 1
  return "$status"
)
