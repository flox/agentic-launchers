# agentic-launchers (build environment)

Source, Nix expressions, and tests for the `agentic-launchers` Flox package.

**This repo is the build environment.** It's where the launchers are developed, packaged, and tested. The **runtime environment** — where the package is consumed by end users — lives elsewhere (see `~/dev/agentic-playground/` for the local test env, or `flox install flox/agentic-launchers` for consumers).

## What gets built

One top-level Flox package, defined by a Nix expression in `.flox/pkgs/agentic-launchers.nix`:

- **`agentic-launchers`** — ships `launch`, the per-tool `launch-*` scripts, shared helpers, `etc/agentic-bootstrap.sh`, and the bundled `_launcher-lock-helper` binary in a single `$out/bin`.

The lock helper is built as a scoped intermediate (`launcher-lock-helper.nix`, `buildGoModule`, stdlib-only) and copied into the same output — it's an implementation detail of the launcher shell layer, not a separate consumable. `flox build launcher-lock-helper` still works if you want to check it in isolation, but consumers install only `agentic-launchers`.

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
flox build agentic-launchers      # produces result-agentic-launchers/{bin,etc}/
                                  # (builds launcher-lock-helper as an intermediate)
```

Wire the freshly-built store path into the runtime env's manifest:

```toml
agentic-launchers.store-path = "/nix/store/…-agentic-launchers-0.1.0"
```

Then `flox activate` in the runtime env and smoke-test `launch <tool>` end-to-end.

## Testing

All three suites are mocked — no live Ollama/omlx/CLI qualification:

```
export LAUNCHER_LOCK_HELPER=/tmp/scratch/result-agentic-launchers/bin/_launcher-lock-helper
bash tests/test-launchers.sh          # 55 checks
bash tests/test-proxy-record-auth.sh  #  7 checks
bash tests/test-lock-crash.sh         #  5 checks
```

Run once as-is and once under `BASH_COMPAT=3.2` for macOS Bash-3.2 compatibility.

## Publishing

Not automated. When ready:

```
flox publish -o flox agentic-launchers
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
