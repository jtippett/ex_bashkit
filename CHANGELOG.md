# Changelog

## [Unreleased]

### Added

- Elixir-backed virtual filesystems. `ExBashkit.Session.new/1` accepts
  `:virtual_fs` — a map of `mount_path => backend` mounting filesystems whose
  reads and writes a script performs under that path are serviced by your
  application (generate content on demand, proxy to a real store). A backend is a
  module implementing the new `ExBashkit.VirtualFs` behaviour (as `module` or
  `{module, arg}`), or a single dispatch function for inline use. Read **and**
  write are supported (`read`/`write`/`append`/`mkdir`/`remove`/`list`/`stat`,
  returning tagged results); `exists` is derived from `stat`, the mount root is a
  directory, `chmod` is a no-op, and `rename`/`copy`/`symlink`/`read_link` are not
  yet proxied. Reuses the custom-builtin back-call bridge (same handler process,
  `:builtin_timeout_ms`, failure isolation, and no-reentrancy rule); composes
  with the in-memory FS, `:files`, and host `:mounts`.
- Custom builtins. `ExBashkit.Session.new/1` accepts `:builtins` — a map of
  `name => fun` registering Elixir-defined virtual executables a script invokes
  as `name args…`. Each builtin is a 1-arity function receiving `%{args, stdin,
  env}` and returning `{:ok, iodata}` (stdout/exit 0), `{:error, iodata}`
  (stderr/exit 1), or a full `%ExBashkit.Result{}`. The call is a blocking
  Rust→Elixir round-trip serviced by a short-lived per-`exec/2` process; a
  handler that raises or exceeds `:builtin_timeout_ms` (default 30_000; exit 124)
  fails only that command, not the session. A builtin must not call `exec/2` on
  the same session (reentrancy deadlock); driving a different session is fine.
- Network access. `ExBashkit.Session.new/1` accepts `:allow_net` — a list of URL
  patterns the `curl`/`wget`/`http` builtins may reach, or `:all` for any host.
  The allowlist is default-deny (a session with no `:allow_net` cannot reach the
  network at all), matches scheme/host/port/path-prefix literally, and does not
  follow redirects. Requests to private/reserved IP ranges are blocked by default
  (SSRF protection); `:block_private_ips` (default `true`) controls this. The NIF
  bundles bashkit's `http_client` feature (reqwest + rustls), so network support
  ships in the precompiled binary; execution moves to a dirty-IO scheduler since
  a networked script can block on a socket. Invalid `:allow_net`/`:block_private_ips`
  values raise from `new/1`.
- Resource limits. `ExBashkit.Session.new/1` accepts `:limits` (keyword list or
  map) to tighten bashkit's execution bounds for untrusted scripts:
  `:max_commands`, `:max_loop_iterations`, `:max_total_loop_iterations`,
  `:max_function_depth`, `:max_input_bytes`, and `:timeout_ms`. Exceeding a limit
  returns `{:error, message}`; unknown keys or non-integer values raise.
- Host directory mounts. `ExBashkit.Session.new/1` accepts `:mounts` —
  `{vfs_path, host_path, mode}` tuples (`:read_only` / `:read_write`) — mapping
  real host directories into a sandbox, plus `:allowed_mount_paths` to opt into
  bashkit's sensitive-path default-deny. bashkit enforces canonicalization and
  symlink/`..` escape rejection; misconfigured mounts (unknown mode, missing or
  non-directory host path) raise from `new/1`. (`:overlay` is intentionally
  unsupported — bashkit has no real-FS overlay mode.)
- Virtual filesystem access from Elixir. `ExBashkit.Session.write_file/3` and
  `read_file/2` place and retrieve files in a session's in-memory filesystem —
  shared with scripts, so the host can stage inputs and pull back results
  (round-tripping arbitrary binary content) without going through a script.
  `Session.new/1` gains a `:files` option to seed files (creating parent dirs)
  up front.
- `ExBashkit.Session` — persistent, stateful sandboxes. Unlike `exec/1`, a
  session's environment variables, working directory, in-memory filesystem,
  shell functions and aliases persist across `ExBashkit.Session.exec/2` calls.
  `ExBashkit.Session.new/1` seeds initial state via `:env`, `:cwd`, `:username`,
  and `:hostname` options. Each session is an independent sandbox and serializes
  its own calls.

### Changed

- Updated `rustler` to 0.38 (Rust crate and Elixir dep) and `rustler_precompiled`
  to 0.9, aligning the previously skewed Rust/Elixir rustler versions.

## 0.1.0

### Added

- Initial project scaffold: Rustler-precompiled NIF wrapper around
  [bashkit](https://github.com/everruns/bashkit) `0.11.0`.
- Stateless `ExBashkit.exec/1` — runs a bash script in a fresh sandbox and
  returns an `%ExBashkit.Result{}` (`stdout`, `stderr`, `exit_code`).
- CI (test/format/clippy) and release (precompiled NIFs for 4 targets)
  GitHub Actions workflows.
- `PORTING.md` (staged porting playbook) and `UPDATE_PROCEDURE.md`
  (bashkit version-bump procedure).

> Not yet wired up: persistent sessions, virtual-filesystem mounts, resource
> limits, network allowlist, Elixir-defined custom builtins, snapshot/resume,
> and the optional `python` / `sqlite` / `typescript` builtins. See `PORTING.md`.
