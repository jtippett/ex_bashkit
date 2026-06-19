# ExBashkit — Session Handoff

You are continuing work on **ExBashkit**, an Elixir NIF wrapper around
[`bashkit`](https://github.com/everruns/bashkit) (a sandboxed, pure-Rust virtual
bash interpreter). Read this, then `PORTING.md` (the staged plan, with a live
status block at §3) and `UPDATE_PROCEDURE.md` (version bumps). This handoff is
uncommitted scratch — keep it refreshed as you go.

---

## TL;DR — where things stand

**Phases 1–8 are shipped to `master`, CI green, 173 tests.** The library wraps
bashkit faithfully (we vendor no execution logic — every semantic comes from
bashkit; we only marshal data). Public surface:

- `ExBashkit.exec/1` — stateless, fresh sandbox per call.
- `ExBashkit.Session` — persistent, stateful sandbox:
  - `new/1` opts: `:env`, `:cwd`, `:username`, `:hostname`, `:files` (seed VFS),
    `:mounts` (`{vfs, host, :read_only|:read_write}`), `:allowed_mount_paths`,
    `:limits`, `:allow_net` (`[url_patterns]` | `:all`), `:block_private_ips`,
    `:builtins` (`%{name => fn call -> ... end}`), `:builtin_timeout_ms`,
    `:virtual_fs` (`%{"/mnt" => fn | module | {module, arg}}`).
  - `exec/2` → `{:ok, %ExBashkit.Result{stdout, stderr, exit_code}}` |
    `{:error, message}` (a non-zero exit is still `:ok`).
  - `write_file/3`, `read_file/2` — host access to the (shared) in-memory/host FS.
  - `snapshot/2` (`:key`/`:exclude_filesystem`/`:exclude_functions`) →
    `{:ok, bytes}`; `restore/3` (`:key`) → `{:ok, session}` | `{:error, msg}`.
    Bytes carry shell state + in-memory FS only, NOT config — resume = rebuild a
    same-capability session, then restore into it.
  - `stat/2`, `list_dir/2`, `mkdir/3`, `remove/3`, `rename/3` — lock-free host FS
    primitives over the (shared) session VFS.
  - `:python` (`true` | `[name(s): …]`) — registers `python`/`python3` running
    sandboxed Python that shares the session FS (optional `:ex_monty` dep). See
    `ExBashkit.Python`.
- `ExBashkit.VirtualFs` — behaviour for `:virtual_fs` backends (worked examples
  in its moduledoc).
- `ExBashkit.Python` — the `python` builtin (optional, `ex_monty`-backed).

**Next: Phase 9 — LLM tool contract helpers** (`ExBashkit.Tool`: emit a JSON
schema + system-prompt text, parse tool calls — the Elixir analogue of bashkit's
`BashTool`; pure Elixir, no Rust feature cost). Phases 7 (python) and 8
(snapshot/resume) are **done**. (P6c later: proxy `mv`/`cp` across virtual mounts;
streaming. Possible future: a monty fork for `sys.argv`; output-byte limits.)

---

## Environment & layout

- **This repo:** `/Users/james/Desktop/lib/ex_bashkit` (git, branch `master`).
- **GitHub:** https://github.com/jtippett/ex_bashkit (public, CI passing).
- **Sibling reference — ExMonty:** `../ex_monty` (wraps the `monty` Python
  interpreter the same way). The *proven template* for resources, serialization,
  release flow, docs. **But** its effect-mediation/lease machinery does NOT port
  (see "the crux" below) — bashkit is push-based.
- **bashkit source checkout:** `../bashkit` (crates at `../bashkit/crates/`).
  Read the real API here; don't guess. crates.io is the source of truth for what
  users build; the checkout may be ahead of the pinned release.
- **Toolchain:** Elixir 1.18 / OTP 27, Rust stable. macOS (darwin), zsh.
- **Continuity:** durable notes live in `~/.claude/projects/-Users-james-Desktop-lib-ex-bashkit/memory/`
  (MEMORY.md index) and the private journal (search it for per-phase gotchas).

**Verify the build first thing:**
```bash
cd /Users/james/Desktop/lib/ex_bashkit
EXBASHKIT_BUILD=1 mix test          # 69 should pass
```
(First build is slow — bashkit + tokio compile from scratch.)

---

## The working loop (this is what's been producing clean phases)

Per phase: **TDD** (write the failing test first — `EXBASHKIT_BUILD=1 mix test`)
→ implement (Rust NIF + Elixir API, marshal-only) → **full gate** (`mix test`,
`mix format --check-formatted`, `cargo fmt --check`, `cargo clippy -- -D warnings`)
→ dispatch the **`superpowers:code-reviewer`** subagent against the diff (it has
caught a real soundness bug every single phase — take it seriously, apply
`receiving-code-review` rigor) → fold fixes → **commit straight to `master`**
(PRs skipped for straightforward work, per the user) → push → watch CI green.
Each phase also gets a README section, CHANGELOG entry, and an `examples/*.exs`.

---

## Key decisions & facts (don't re-litigate)

- **Pin bashkit by exact crates.io semver** (`=0.11.0`) with
  `default-features = false, features = ["realfs"]`. `realfs` (host mounts) is a
  no-dep feature gate, compiled into the default build; mounting is default-deny
  at runtime.
- **`exec` is async** → one shared multi-thread tokio runtime + `block_on` inside
  a **dirty** NIF. Never a runtime per call; never `block_on` in a non-dirty NIF.
- **Resource = `ResourceArc<Mutex<Bash>>`** plus the FS handle from `bash.fs()`
  (the *real* layered `MountableFs`, not a raw `InMemoryFs`) wrapped in
  `AssertUnwindSafe` (rustler's `catch_unwind` needs `RefUnwindSafe`). The `exec`
  lock recovers from poisoning so a bashkit panic can't brick a session.
- **Host mounts: only `:read_only` / `:read_write`.** bashkit has no real-FS
  overlay mode → `:overlay` dropped. **No Mount resource / lease** — push model
  means mounts are builder config. bashkit silently skips refused mounts, so we
  probe `fs.exists(vfs)` post-build and raise. Sensitive-path denylist includes
  `/private` (→ macOS temp dirs need `:allowed_mount_paths`).
- **Limits** are session-level (builder), per-script. Output-byte caps deferred
  (they truncate, not error → need `%Result{}` fields → breaks doctests).
- **Network: `:allow_net` (default-deny) + `:block_private_ips` (default true,
  SSRF).** `http_client` (reqwest+rustls) is baked into the shipped NIF. Gotcha:
  it's declared as *our own* default Cargo feature `http_client =
  ["bashkit/http_client"]` — a bare `features = ["http_client"]` on the bashkit
  dep would build it but leave `#[cfg(feature = "http_client")]` in our code
  permanently false (it checks *our* crate's features), so `.network()` would
  never run. bashkit installs the `ring` crypto provider itself. `session_exec`
  is `DirtyIo` (sockets block); stateless `exec/1` stays `DirtyCpu`.
- **Custom builtins (`:builtins`) = the back-call bridge.** Per-exec `spawn_link`
  handler process; `req_id`-keyed global `oneshot` table; `builtin_reply` NIF.
  Three traps that bit us (all in the Phase 6 design doc): (1) `OwnedEnv::send_*`
  **panics on a BEAM thread** → send via `spawn_blocking`; (2) bashkit's own
  `:timeout_ms` **drops** the exec future, so the table slot needs a
  `PendingCleanup` RAII guard or it leaks; (3) the reply NIF takes `i32`, so
  `%Result{exit_code}` is masked `band 0xFF` Elixir-side or it crashes the linked
  caller. Handler pid travels as a bashkit `ExecutionExtensions` value.
- **Virtual filesystems (`:virtual_fs`) reuse the builtin bridge** but FS trait
  methods get only `&Path` (no `Context`), so the per-exec handler pid travels via
  a shared `Arc<Mutex<Option<CallTarget>>>` cell on `SessionResource`, set/cleared
  in `session_exec` (safe — a session's execs are serialized; sessions each own
  their cell). Separate `pending_fs_calls`/`fs_reply`/`PendingFsCleanup`. Contract
  is the **Plug-style dual** (`ExBashkit.VirtualFs` behaviour *or* a fn) — chosen
  after a materialized José/Sasa comparison; the builtins one-fn symmetry is a
  false friend for a multi-op entity. FS errors via `io::Error::into()`
  (`fs_errors` isn't root-exported). Derived `stat` uses `with` (type-checker).
- **rustler is 0.38** (Rust + Elixir). They were skewed (Elixir floated to 0.38
  via `~> 0.37`; Rust capped at 0.37 via `"0.37"`). If you bump again, move both.
  `release.yml`'s `nif-2.15` artifact name is correct on OTP 27 — re-verify at
  release time (it self-checks via the precompiled checksum step).
- **NIF ABI `nif-2.15`** hardcoded in `release.yml` artifact names — keep synced
  with rustler.
- **Hex publish is deferred** until the whole port is done; the user publishes.
  Never `hex.publish` or push tags without an explicit, fresh go-ahead.

---

## The architectural crux (internalize before Phase 6)

bashkit's effect model differs fundamentally from monty's, and it shapes the port.

- **monty (ExMonty)** is *pull-based*: the run loop **yields** each effect to
  Elixir as a return value (`{:os_call, …}`) and you `resume/2`. Nobody holds a
  scheduler while the host thinks; trivially snapshot/resume across nodes.
- **bashkit** is *push-based + async*: you configure capabilities up front
  (`Bash::builder()`) and effects are **serviced inside the async run**.

**Consequences to design around:**
1. The **simple paths stay trivial** — async is invisible (Phases 1–4 prove it).
2. **Dynamic capability IS supported** but the host callback is the one real cost:
   a **blocking Rust→Elixir round-trip** (`OwnedEnv` + `send` to a pid, block on a
   reply channel) that **pins a dirty scheduler thread for the script's duration**.
   So: bound concurrency / pool sessions, and forbid the handler from re-entering
   the *same* locked session (deadlock).
3. **Don't rebuild monty's yield loop.** Pre-grant capabilities up front (VFS,
   mounts, limits, allowlist) to cover the 80% case with zero callbacks. The
   channel-bridge belongs only in Phase 6 (custom builtins) — build/prove it via
   streaming output first if possible.

`Snapshot` (Phase 8) saves whole sessions at command boundaries — it is NOT a
pause-mid-effect primitive.

---

## Open questions for the user (raise when relevant)

- **Phase 5:** enable `http_client` by default (bigger build) vs opt-in?
- Output-byte limits + `%Result{}` truncation flags — do them as a small phase?
- `python` feature needs a git source for bashkit (monty isn't on crates.io) —
  breaks the clean crates.io pin. Enable only if/when the user wants it.
- ExBashkit semver line as the API grows (ExMonty treats big additive features as
  minor `0.x` bumps).
