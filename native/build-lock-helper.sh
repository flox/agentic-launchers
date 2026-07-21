#!/usr/bin/env bash
set -euo pipefail

case "${BASH_SOURCE[0]}" in
  */*) source_parent="${BASH_SOURCE[0]%/*}" ;;
  *) source_parent="." ;;
esac
ROOT="$(cd -- "$source_parent/.." && pwd -P)"
unset source_parent
SOURCE="$ROOT/native/launcher-lock-helper"

command -v go >/dev/null 2>&1 || {
  echo "Error: Go is required to build launcher lock helpers" >&2
  exit 1
}

build_one() {
  local goos="$1" goarch="$2" output="$3"
  CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
    go build -trimpath -buildvcs=false -ldflags='-s -w -buildid=' \
      -o "$ROOT/bin/$output" "$SOURCE/main.go"
  chmod 755 "$ROOT/bin/$output"
}

build_one linux amd64  _launcher-lock-helper-linux-amd64
build_one linux arm64  _launcher-lock-helper-linux-arm64
build_one darwin amd64 _launcher-lock-helper-darwin-amd64
build_one darwin arm64 _launcher-lock-helper-darwin-arm64
