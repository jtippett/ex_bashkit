# Changelog

## [Unreleased]

### Added

- `ExBashkit.Session` — persistent, stateful sandboxes. Unlike `exec/1`, a
  session's environment variables, working directory, in-memory filesystem,
  shell functions and aliases persist across `ExBashkit.Session.exec/2` calls.
  `ExBashkit.Session.new/1` seeds initial state via `:env`, `:cwd`, `:username`,
  and `:hostname` options. Each session is an independent sandbox and serializes
  its own calls.

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
