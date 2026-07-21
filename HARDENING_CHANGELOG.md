# Launcher hardening changelog

Date: 2026-07-21

This corrective pass supersedes the earlier hardening changelogs. It retains the kernel-managed descriptor-lock architecture and closes the remaining functional and identity defects reported after that pass:

- oMLX credentials are exported to executed clients;
- proxy applied state binds the complete launcher-side service configuration, not only the model;
- every schema-v2 proxy record validates its own field/digest relationship before it can influence recovery or a fast-path decision;
- full Hugging Face repository requests require authenticated oMLX provenance;
- direct slashless launcher execution resolves helper paths correctly;
- FIFO lock-path substitution cannot block the shell before native validation; and
- atomic replacement no longer uses command-line `mv` semantics.

## Corrections in this pass

### oMLX credentials and selected-model identity are exported

`omlx_ensure_model` now exports both:

- `OMLX_API_KEY`: the key successfully verified against the requested oMLX endpoint; and
- `OMLX_MODEL_ID`: the server-visible model ID accepted only after the requested model is visible and, for a full repository ID, its source provenance is proven.

`launch-codex-omlx` continues to configure Codex with `env_key="OMLX_API_KEY"`, but the executed Codex process now actually receives that variable. All other oMLX launchers consume the same verified, exported identity.

### Proxy committed state binds complete configuration

`bin/_proxy-ensure.sh` now uses schema-v2 records. A committed record contains:

- service name;
- selected model;
- normalized health/listen URL;
- a SHA-256 runtime identity; and
- a SHA-256 applied identity over the model plus runtime identity.

Every proxy caller supplies an ordered semantic tuple containing all launcher-controlled inputs that affect the service, including normalized upstream and listener URLs, backend type, a non-secret credential digest where applicable, and an explicit protocol/configuration revision.

A fast-path success requires all of the following:

1. desired model equals the request;
2. the complete committed identity equals the request; and
3. the requested listener is healthy.

Changing an endpoint, listener, credential identity, backend, or protocol revision therefore forces a restart even when the model string is unchanged. Legacy model-only committed state is accepted for migration but never accepted as complete applied-state evidence; it forces a schema-v2 restart and commit.

Durable transition records contain complete target and previous records. Recovery is allowed only when the current invocation matches one recorded identity. Automatic rollback is attempted only when the current process can truthfully recreate the previous runtime identity; otherwise the transition is retained and the operation fails closed.

### Proxy records validate internal integrity and complete request identity

Schema-v2 committed, transition-target, and transition-previous records are no longer accepted merely because their fields are present and their digests are syntactically SHA-256-shaped.

For every parsed record, the helper now:

1. requires exactly the schema-defined keys and canonical lowercase SHA-256 encodings;
2. validates all scalar fields and the canonical listener URL;
3. recomputes the applied identity as
   `SHA-256("proxy-applied-v2", service, model, runtime_id)` using the same NUL-delimited tuple function as the writer; and
4. rejects the record unless the recomputed and stored identities are equal.

The writer performs the same recomputation before it will serialize a new record. This prevents an internally inconsistent record from being introduced through a defective caller as well as rejecting corruption or mismatched restoration on read.

The committed fast path and schema-v2 transition recovery now compare the complete parsed tuple against the current request:

- service;
- model;
- canonical listener URL;
- runtime identity; and
- applied identity.

Service/path mismatches fail explicitly. A digest-consistent record whose listener or runtime tuple belongs to another request cannot reach the health-check fast path and cannot be selected as a transition side.

The SHA-256 value is a deterministic integrity binding, not a secret-key MAC. It detects accidental corruption, inconsistent records, defective migration, and mismatched state/request combinations. It does not prevent a hostile same-account actor with write access from replacing every field and recomputing the digest; that remains part of the documented local-path trust boundary.

### oMLX repository provenance is enforced

The public `/v1/models` catalog can expose a short model ID that does not prove which full Hugging Face repository produced it. Full repository requests now use a provenance-aware flow:

- downloads are serialized by canonical endpoint plus the server-visible short-name namespace, so repositories such as `org-A/shared` and `org-B/shared` cannot run under separate locks while colliding in oMLX;
- authenticated `/admin/api/models` inventory must contain exactly one record whose `source_repo_id` equals the requested repository;
- that record's server-visible `id` must be unique in the inventory and, when the public catalog already exposes a candidate, must equal that public ID;
- an existing short-name model with absent, conflicting, duplicated, malformed, or unreachable provenance is rejected before any download request;
- download-start responses and later task snapshots must bind the exact requested `repo_id`; and
- a successful proof is recorded durably under the cache for diagnostics and recovery evidence.

Slashless local model IDs remain supported as local identities. They must still be unambiguous in `/v1/models`.

### Direct launcher execution is slash-safe

Every `launch-*` script and each shared ensure helper now resolves its directory from `BASH_SOURCE[0]` using an explicit slash/no-slash case followed by `pwd -P`.

Both installed PATH execution and direct forms such as:

```bash
cd bin
bash launch-aider --model example
```

therefore source the intended adjacent helpers rather than attempting to read `launch-aider/_ollama-ensure.sh`.

### FIFO lock-path opens fail promptly

The Bash owner opens persistent lock files read/write rather than write-only. On the qualified Linux platform, an intervening FIFO substitution therefore cannot block waiting for a reader before the native helper runs. The native helper then rejects the descriptor and pathname because they are not the same regular, non-symlink inode.

This closes the reported pre-helper hang while retaining inherited-descriptor lock ownership.

### Atomic replacement uses native `rename(2)` semantics

`launcher_atomic_write_file` no longer invokes command-line `mv`.

The packaged native helper now supports:

```text
replace-file <source> <target>
```

It:

1. opens the same-directory temporary with `O_NOFOLLOW`;
2. binds the open descriptor to the source pathname's device/inode;
3. rejects an existing non-regular or symlink target;
4. invokes `rename(2)` directly, avoiding `mv`'s “move into a directory” behavior; and
5. verifies that the final target is a regular non-symlink path naming the exact open source inode.

This eliminates the demonstrated destination-directory redirection semantics. During stress qualification, the execution environment also exposed an intermittent GNU `mv` failure that misclassified an absent repeated destination as a directory; direct `rename(2)` removes that dependency as well.

Durable callers retain the existing filesystem-wide `sync` barrier after verified publication.

## Kernel-managed authority retained

The custom PID/start-token/pathname lease and heartbeat subsystem remains deleted. A packaged native helper acquires `flock(2)` on a descriptor opened and retained by the Bash owner.

The helper validates before and after acquisition that:

- the inherited descriptor names a regular file;
- the pathname is a regular, non-symlink file;
- descriptor and pathname identify the same device and inode; and
- the Bash parent that requested authority is still alive.

The helper exits without unlocking. Authority remains attached to the inherited open-file description until the owner and any still-running protected children close it.

Consequently:

- a hard-killed owner with no live protected child releases automatically;
- a protected child that survives its launcher retains authority until it exits;
- there is no stale-owner metadata or heartbeat process;
- persistent lock paths are never reclaimed or unlinked, eliminating the previous ABA takeover race; and
- release failures are explicit and retained descriptor state is not silently discarded.

The primitive protects configuration and credential publication, Ollama pulls, oMLX downloads and journals, and proxy transitions/restarts.

## Other retained hardening

- `OLLAMA_HOST` is normalized as a complete URL, including explicit schemes, paths, scheme-specific default ports, IPv6, and wildcard-listen mapping for clients.
- Ollama pulls are endpoint/model serialized and use durable intent journals for indeterminate synchronous POST outcomes.
- oMLX downloads use durable intent/task journals, bounded polling, exact task/repository identity, handled cancellation, and verified post-download visibility.
- oMLX admin-login transport errors are explicit rather than disappearing under `set -e`.
- client profiles bind model, canonical endpoint, proxy address where relevant, protocol, and credential identity.
- `flox services restart` has a wall-clock deadline and bounded descendant-process termination.
- `launcher_profile_key` requires SHA-256 and NUL-delimits tuple components.
- the original brief's dispatch, usage, missing-backend, model-option, resolver, backend-self-detection, private-mode, and JSON-generation corrections remain in place.

## Validation

### Main mocked integration suite

```bash
bash tests/test-launchers.sh
BASH_COMPAT=3.2 bash tests/test-launchers.sh
```

Both modes pass the following checks:

1. explicit bare-launch usage;
2. singular missing-backend errors;
3. real-backend passthrough;
4. dedicated launcher dispatch and aliases;
5. resolver argument boundaries;
6. symlink-safe backend discovery;
7. direct-launcher model forms;
8. complete Ollama URL normalization;
9-10. concurrent and crash-indeterminate Ollama pull behavior;
11-15. proxy transaction recovery, desired/committed separation, serialization, checked rollback, and bounded restart with descendant termination;
16-18. atomic publication under contention, invalid-target rejection, and proof that publication uses native descriptor-bound rename rather than command-line `mv`;
19-21. endpoint-, proxy-, model-, and credential-bound client profile identity;
22-25. oMLX discovery classes, explicit login failures, completed-but-absent rejection, and delayed registration;
26-29. endpoint/model-scoped oMLX concurrency, cancellation, durable task resumption, and unknown-POST handling;
30-38. kernel authority lifetime, hard-kill recovery, child inheritance, contender exclusion, release diagnostics, inode binding, SHA-256 keys, and packaged target coverage;
39. slashless direct Codex execution receives the resolved oMLX key and proven server model ID, with static coverage for every launcher;
40. same-model proxy requests restart exactly when the complete endpoint/configuration identity changes;
41. wrong-repository short-name collisions and duplicated server-visible IDs are rejected before download, and colliding repository names share one lock namespace;
42. FIFO lock objects fail promptly rather than blocking before native validation;
43. recovered oMLX task IDs are bound to the exact repository;
44. committed model/digest mismatches fail before restart or health acceptance;
45. committed service/digest mismatches and digest-consistent foreign-service records fail closed;
46. malformed transition-target identities are rejected;
47. malformed transition-previous identities are rejected;
48. committed fast-path selection compares the complete record tuple;
49. transition recovery compares the complete target/previous tuples; and
50. every shipped shell file passes `bash -n`.

The suite now passes **50/50** checks in each mode. Readiness waits used by its hard-kill cases are bounded and verify that the producing process remains alive, so a setup failure reports its exit status instead of hanging indefinitely.

### Dedicated proxy-record authority qualification

```bash
bash tests/test-proxy-record-auth.sh
BASH_COMPAT=3.2 bash tests/test-proxy-record-auth.sh
```

Both modes pass **7/7** focused checks covering:

1. committed model/digest inconsistency;
2. committed service/digest inconsistency and path binding;
3. transition-target identity inconsistency;
4. transition-previous identity inconsistency;
5. complete committed-tuple comparison;
6. complete transition-side comparison; and
7. canonical lowercase schema-v2 SHA-256 values.

### Production-operation hard-crash qualification

```bash
bash tests/test-lock-crash.sh
BASH_COMPAT=3.2 bash tests/test-lock-crash.sh
```

Both modes pass **5/5** checks. Each kills the shell executing the protected operation while its child remains active, proves a contender cannot enter, then proves recovery can acquire after the child exits:

1. atomic configuration publication;
2. no-clobber credential publication;
3. Ollama pull;
4. oMLX download/task polling; and
5. proxy transition/service restart.

### Focused qualification

- 100 consecutive native atomic replacements to the same pathname completed successfully with the final content verified.
- The native helper was rebuilt twice for Linux amd64/arm64 and macOS amd64/arm64; every rebuilt binary was byte-for-byte identical.
- `gofmt` and `go vet` passed for the helper source.
- Production shell sources contain none of the scanned Bash-4-only constructs and all shell files pass `bash -n`.

## Deliberate boundaries and qualification limits

- `flock(2)` is advisory. Correctness assumes all cooperating launchers use the same lock path and the filesystem provides mutually coherent `flock` semantics for participating processes. The helper fails closed on syscall errors but cannot certify every network/distributed filesystem.
- A hostile same-account process can still replace pathnames after the helper's final validation or after a publication postcondition. Fully defending that threat requires trusted directory capabilities and descriptor-relative operations extending beyond the supplied launcher architecture.
- Read/write FIFO opening and all native-helper runtime behavior were executed on Linux only. The packaged macOS helpers cross-compile successfully but were not run on macOS.
- The proxy `/health` endpoint does not independently attest the model or complete configuration it serves. The launcher now detects its own requested configuration changes and recovers incomplete transactions, but service-side identity attestation requires proxy support.
- A shared `llamacpp-proxy-*` service still serves one model/configuration at a time. A later switch can interrupt an existing client. Eliminating that requires per-model service topology outside the supplied bundle.
- Ollama's synchronous pull API provides no durable task identifier or cancellation endpoint. Permanently indeterminate journals may require operator inspection.
- The oMLX provenance flow depends on the authenticated admin inventory continuing to expose repository source identity. Missing, changed, unreachable, or ambiguous inventory fails closed.
- Durable publication uses a conservative global `sync`, not targeted file and parent-directory `fsync`.
- Process-tree termination is portable best effort. A descendant that fully daemonizes and reparents before discovery is outside that mechanism.
- Integration tests are mocked. No pinned live qualification was run against Ollama, oMLX, Flox services, Codex, OpenCode, OpenClaw, Crush, or the other target CLIs.
- Native Apple Bash 3.2 was unavailable. `BASH_COMPAT=3.2` on Bash 5.2 is useful compatibility evidence but is not equivalent.
- ShellCheck was unavailable in the execution environment.
