# Changelog

## [Unreleased]

## 0.1.6 - 2026-07-15

### Fixed

- A `:virtual_fs` backend returning a directory-entry name that resolves back
  onto the directory being listed — an empty string, `.`, `..`, or a name
  containing a path separator — could send a recursive builtin (`find`,
  `grep -r`) into unbounded recursion. Such names are now rejected at the bridge:
  the offending `list` fails as a bounded I/O error and the walk stops cleanly.
  (Legitimately deep trees remain bounded by bashkit's existing path-depth cap.)
- Custom builtins and `:virtual_fs` backends that terminate via an uncatchable
  process exit no longer take down the linked `Session.exec/2` caller. Callback
  failures are isolated as command/I/O errors, while script-timeout teardown
  still kills in-flight callback work so it cannot land late side effects.
- `:builtin_timeout_ms` now rejects values above the BEAM receive ceiling at
  session construction; such a value previously raised `:timeout_value` inside
  the linked handler only when a callback ran.
- Host mounts refused by bashkit are now policy-checked before build. A refused
  mount targeting an existing default VFS directory (notably `/tmp`) previously
  fooled the post-build existence check and returned a session with the requested
  mount silently absent.
- Virtual-FS listings now reject invalid UTF-8, invalid entry type tags, and all
  no-progress/escaping names before crossing the NIF bridge (with the native
  validation retained as defense in depth). Builtin names and VFS/host mount
  points likewise reject values the native/router layers cannot represent or
  route unambiguously.
- An allocation failure while encoding builtin stdin or virtual-FS write data no
  longer silently substitutes an empty binary and reports a successful bridge
  send; the operation fails cleanly instead.
- Updated transitive `anyhow` from 1.0.102 to 1.0.103, which fixes
  RUSTSEC-2026-0190 (`Error::downcast_mut` borrow-rule unsoundness).

## 0.1.5 - 2026-07-15

### Changed

- Updated the bundled bashkit interpreter to **0.13.0** (from 0.11.0). No changes
  to the ExBashkit API. Notable interpreter improvements scripts pick up:
  - `xargs -P/--max-procs` runs command batches concurrently, with
    `--process-slot-var` exposing the slot index to each child.
  - `ls -d/--directory` lists directories themselves instead of their contents,
    and long-format `ls` renders actual UTC calendar dates.
  - `$HOME` is now a writable directory (the VFS provisions the user home).
  - Glob `*` matching is now linear-time, closing an exponential-blowup DoS on
    adversarial patterns.
  - A batch of interpreter correctness and security fixes (getopts cursor reset
    across shell boundaries, `read` whitespace handling, snapshot restore
    validation, and more).

## 0.1.4 - 2026-06-26

### Added

- `ExBashkit.Pool` — an optional, supervised bounded-concurrency gate for running
  untrusted scripts under load. Each `exec` occupies a dirty scheduler thread for
  the script's duration, so unbounded concurrency of untrusted scripts can exhaust
  the (bounded) dirty pool. The pool caps concurrent runs with permits plus a
  bounded queue, shedding excess load with `{:error, :overloaded}`. Opt in by
  adding it to your supervision tree; `:size` / `:max_queue` are configurable via
  child-spec options or `config :ex_bashkit, pool_size: …, pool_max_queue: …`.
- Application-environment hardening knobs for nodes running untrusted scripts:
  `:max_reply_bytes` (cap on a single custom-builtin / `:virtual_fs` reply;
  default 16 MB) and `:max_timeout_ms` (a hard ceiling every session's
  `:timeout_ms` must respect; default `nil` — no ceiling). See the "Hardening for
  untrusted load" section of `ExBashkit.Session`.

### Changed

- Custom-builtin and `:virtual_fs` replies are now bounded by `:max_reply_bytes`
  before crossing the native boundary: an oversized reply fails that one
  command/op instead of being copied across the bridge. Covers builtin
  stdout/stderr, error/diagnostic strings, and virtual-filesystem reads and
  directory listings.
- `:virtual_fs` back-calls now run in a child process bounded by
  `:builtin_timeout_ms` (brutal-killed on timeout), matching custom builtins. A
  slow backend no longer blocks later back-calls in the same `exec`, and can no
  longer land a write after the operation has already timed out.

## 0.1.3 - 2026-06-20

### Added

- The `jq` builtin (JSON processing) is now bundled — bashkit's `jq` feature
  (the pure-Rust `jaq` engine) is enabled in the precompiled NIF, so scripts can
  pipe through `jq` (e.g. `curl … | jq '.field'`). Pure computation, no extra
  runtime gate.

## 0.1.2 - 2026-06-20

First release. An Elixir NIF wrapper around
[bashkit](https://github.com/everruns/bashkit) `0.11.0` — a sandboxed, in-process
virtual bash interpreter written in Rust. Every execution semantic comes from
bashkit; ExBashkit only marshals data across the NIF boundary.

### Added

- Stateless `ExBashkit.exec/1` — runs a bash script in a fresh sandbox and returns
  an `%ExBashkit.Result{}` (`stdout`, `stderr`, `exit_code`). A non-zero exit is
  still `{:ok, ...}` — the script ran.
- `ExBashkit.Session` — persistent, stateful sandboxes. Unlike `exec/1`, a
  session's environment variables, working directory, in-memory filesystem, shell
  functions and aliases persist across `ExBashkit.Session.exec/2` calls.
  `ExBashkit.Session.new/1` seeds initial state via `:env`, `:cwd`, `:username`,
  and `:hostname`. Each session is an independent sandbox and serializes its own
  calls.
- Virtual filesystem access from Elixir. `ExBashkit.Session.write_file/3` and
  `read_file/2` place and retrieve files in a session's in-memory filesystem —
  shared with scripts, so the host can stage inputs and pull back results
  (round-tripping arbitrary binary content) without going through a script.
  `Session.new/1` gains a `:files` option to seed files (creating parent dirs) up
  front.
- Host directory mounts. `ExBashkit.Session.new/1` accepts `:mounts` —
  `{vfs_path, host_path, mode}` tuples (`:read_only` / `:read_write`) — mapping
  real host directories into a sandbox, plus `:allowed_mount_paths` to opt into
  bashkit's sensitive-path default-deny. bashkit enforces canonicalization and
  symlink/`..` escape rejection; misconfigured mounts (unknown mode, missing or
  non-directory host path) raise from `new/1`. (`:overlay` is intentionally
  unsupported — bashkit has no real-FS overlay mode.)
- Resource limits. `ExBashkit.Session.new/1` accepts `:limits` (keyword list or
  map) to tighten bashkit's execution bounds for untrusted scripts:
  `:max_commands`, `:max_loop_iterations`, `:max_total_loop_iterations`,
  `:max_function_depth`, `:max_input_bytes`, and `:timeout_ms`. Exceeding a limit
  returns `{:error, message}`; unknown keys or non-integer values raise.
- Network access. `ExBashkit.Session.new/1` accepts `:allow_net` — a list of URL
  patterns the `curl`/`wget`/`http` builtins may reach, or `:all` for any host.
  The allowlist is default-deny (a session with no `:allow_net` cannot reach the
  network at all), matches scheme/host/port/path-prefix literally, and does not
  follow redirects. Requests to private/reserved IP ranges are blocked by default
  (SSRF protection); `:block_private_ips` (default `true`) controls this. The NIF
  bundles bashkit's `http_client` feature (reqwest + rustls), so network support
  ships in the precompiled binary. Invalid `:allow_net`/`:block_private_ips`
  values raise from `new/1`.
- Custom builtins. `ExBashkit.Session.new/1` accepts `:builtins` — a map of
  `name => fun` registering Elixir-defined virtual executables a script invokes as
  `name args…`. Each builtin is a 1-arity function receiving
  `%{args, stdin, env, cwd}` and returning `{:ok, iodata}` (stdout/exit 0),
  `{:error, iodata}` (stderr/exit 1), or a full `%ExBashkit.Result{}`. The call is
  a blocking Rust→Elixir round-trip serviced by a short-lived per-`exec/2` process;
  a handler that raises or exceeds `:builtin_timeout_ms` (default 30_000; exit 124)
  fails only that command, not the session. A builtin must not call `exec/2` on the
  same session (reentrancy deadlock); driving a different session is fine.
- Elixir-backed virtual filesystems. `ExBashkit.Session.new/1` accepts
  `:virtual_fs` — a map of `mount_path => backend` mounting filesystems whose reads
  and writes a script performs under that path are serviced by your application
  (generate content on demand, proxy to a real store). A backend is a module
  implementing the `ExBashkit.VirtualFs` behaviour (as `module` or `{module, arg}`),
  or a single dispatch function for inline use. Read **and** write are supported
  (`read`/`write`/`append`/`mkdir`/`remove`/`list`/`stat`, returning tagged
  results); `exists` is derived from `stat`, the mount root is a directory, `chmod`
  is a no-op, and `rename`/`copy`/`symlink`/`read_link` are not yet proxied.
  Composes with the in-memory FS, `:files`, and host `:mounts`.
- Host filesystem primitives on `ExBashkit.Session`: `stat/2`, `list_dir/2`,
  `mkdir/3`, `remove/3`, `rename/3` — lock-free introspection/mutation of a
  session's (shared) virtual filesystem, alongside `read_file/2`/`write_file/3`.
- Snapshot & resume. `ExBashkit.Session.snapshot/2` captures a session's shell
  state (variables, env, cwd, aliases, functions) and in-memory filesystem
  contents as a binary; `ExBashkit.Session.restore/3` loads it back into a session,
  returning `{:ok, session}` or `{:error, message}`. A snapshot carries interpreter
  state, not session *config* (custom `:builtins`, `:virtual_fs` backends, host
  `:mounts`, `:limits`), so to resume you rebuild a session with the same
  capabilities and restore into it; restore validates the whole snapshot before
  mutating, leaving the session usable on a bad/tampered/wrong-key load. `snapshot/2`
  options: `:key` (a non-empty binary → HMAC-keyed snapshot for crossing trust
  boundaries; the matching key is required on restore, and a wrong key or tampered
  bytes are rejected — without a key the embedded digest detects accidental
  corruption only), `:exclude_filesystem`, and `:exclude_functions`.
- Sandboxed `python` builtin. `ExBashkit.Session.new(python: true)` registers
  `python`/`python3` virtual executables that run sandboxed Python (via the optional
  `:ex_monty` dependency) **sharing the session's virtual filesystem** — a file a
  bash step writes, the Python reads, and vice versa. Supports `python file.py`,
  `python -c "…"`, and a program piped on stdin; Python's `pathlib`/`os` filesystem
  operations are routed to the session, while every other effect (network, clocks)
  is denied. A Python error or timeout fails only that command, not the session.
  Opt-in by adding `:ex_monty` to your deps; ExBashkit compiles and runs without it,
  and `python: true` raises a helpful error if it is absent. (Limitations: no
  `sys.argv`; `pathlib.Path` I/O, not `open()`.) See `ExBashkit.Python`.
- LLM tool recipe. A session can be used as an agent "bash" tool with a small
  amount of plain data (a JSON schema, a system prompt, and a function that runs a
  tool call and formats the result) — documented in the README and a runnable
  `examples/llm_tool.exs` (with a ReqLLM wiring snippet). Deliberately *not* a
  module: the glue is framework-specific and tiny, so ExBashkit stays agnostic.
