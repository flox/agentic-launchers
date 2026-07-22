# agentic-launchers (build environment)

Source, Nix expressions, and tests for the `agentic-launchers` Flox package.

**This repo is the build environment.** It's where the launchers are developed, packaged, and tested. The **runtime environment** — where the package is consumed by end users — lives elsewhere (see `~/dev/agentic-playground/` for the local test env, or `flox install flox/agentic-launchers` for consumers).

## What gets built

Two Flox packages, defined by Nix expressions in `.flox/pkgs/`:

- **`agentic-launchers`** — the shell wrappers (`ollama`, `omlx`, `launch-*`, shared helpers, `etc/agentic-bootstrap.sh`). `stdenv.mkDerivation`, no shebang patching.
- **`launcher-lock-helper`** — the `flock(2)`-based Go binary that arbitrates concurrent launcher runs. `buildGoModule`, stdlib-only.

Together they replace the per-arch precompiled binaries the earlier hardening pass shipped.

## Layout

```
bin/                             launch dispatcher, per-tool launch-* scripts, shared helpers
native/launcher-lock-helper/     Go source for the lock helper
etc/agentic-bootstrap.sh         env exports sourced by the runtime env's [hook]
.flox/pkgs/                      Nix expressions for both packages
tests/                           mocked test suites (62 checks)
docs/                            historical briefs and reference docs
```

The manifest in `.flox/env/manifest.toml` here defines only what's needed to **build** — Go, jq, git, etc. It does **not** install the AI CLIs themselves; those live in the runtime env's manifest.

## Building

This repo is registered on FloxHub, so `flox build` refuses to run directly. Work in a pulled copy:

```
flox pull --copy -d /tmp/scratch flox/agentic-launchers
# sync in-tree edits to /tmp/scratch/ (bin/, etc/, native/, .flox/pkgs/)
cd /tmp/scratch
git init -q && git add -A && git commit -qm dev
flox build launcher-lock-helper   # produces result-launcher-lock-helper/bin/_launcher-lock-helper
flox build agentic-launchers      # produces result-agentic-launchers/{bin,etc}/
```

Wire the freshly-built store paths into the runtime env's manifest as:

```toml
launcher-lock-helper.store-path = "/nix/store/…-launcher-lock-helper-0.1.0"
agentic-launchers.store-path    = "/nix/store/…-agentic-launchers-0.1.0"
```

Then `flox activate` in the runtime env and smoke-test `launch <tool>` end-to-end.

## Testing

All three suites are mocked — no live Ollama/omlx/CLI qualification:

```
export LAUNCHER_LOCK_HELPER=/tmp/scratch/result-launcher-lock-helper/bin/_launcher-lock-helper
bash tests/test-launchers.sh          # 50 checks
bash tests/test-proxy-record-auth.sh  #  7 checks
bash tests/test-lock-crash.sh         #  5 checks
```

Run once as-is and once under `BASH_COMPAT=3.2` for macOS Bash-3.2 compatibility.

## Publishing

Not automated. When ready:

```
flox publish -o flox agentic-launchers
flox publish -o flox launcher-lock-helper
```

Requires a clean tree, pushed commits, and `flox auth login`.

## Docs

- [`docs/BRIEF.md`](docs/BRIEF.md) — scope of the correctness/robustness hardening pass
- [`docs/HARDENING_CHANGELOG.md`](docs/HARDENING_CHANGELOG.md) — what that pass added
- [`docs/BRIEF-MACOS.md`](docs/BRIEF-MACOS.md) — original macOS / `omlx` integration design
- [`docs/FLOX.md`](docs/FLOX.md) — general Flox authoring reference
- [`CLAUDE.md`](CLAUDE.md) — repo guide for Claude Code agents

## License

TBD.
