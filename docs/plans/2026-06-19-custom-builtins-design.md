# Phase 6 — Elixir-defined custom builtins (the back-call bridge)

Status: design approved 2026-06-19. Implementation follows the per-phase loop
(TDD → gate → `superpowers:code-reviewer` → fold → ship to `master`).

## Goal

Let an Elixir application register **virtual executables** a sandboxed script can
invoke. A script line `db_query "select …"` calls back into the host
application, which computes a result and hands it back as the command's output.
This is bashkit's canonical extension point and the first time ExBashkit needs a
**blocking Rust→Elixir round-trip** — every phase so far pre-granted capabilities
up front with zero callbacks.

Scope this phase: **custom builtins only.** The dynamic (Elixir-backed)
`FileSystem` is a required feature but is sequenced as the *next* phase (6b); it
reuses the identical bridge (request-id table, delivery NIF, per-exec handler
pid), so building builtins first proves the mechanism on a one-method surface
before multiplying it across the ~6-method FS trait.

## Why a bridge is needed (the architectural crux)

bashkit is **push-based**: capabilities are configured up front and effects are
serviced *inside* the async `exec` we already `block_on`. A custom builtin is an
`async fn execute(&self, ctx) -> Result<ExecResult>` that runs mid-execution. To
service it from Elixir we must leave Rust, run host code, and come back — while
the script (and the dirty-scheduler thread running it) waits.

Critically, the Elixir process that called `exec/2` is **blocked in the NIF** for
the whole script. So the back-call cannot be handled by that process — it must be
handled by a *different* one. That single fact drives the architecture.

## Architecture

### Registration (build time)

`Session.new(builtins: %{"name" => fun})` stores the closures in the Elixir
`%Session{}` struct as plain data. The Rust side is told only the **names**
(a `Vec<String>`) and registers one `Box<dyn Builtin>` per name via the builder's
`.builtin(name, …)`. Rust never holds an Elixir closure.

### Per-exec wiring

`Session.exec/2`:

1. Spawns a short-lived **handler process `H`**, seeded with the builtins map and
   timeout. `H` is a simple receive loop, *not* a long-lived GenServer — so there
   is no process to leak and no NIF-resource-destructor lifecycle to manage.
2. Calls `Native.session_exec(ref, script, h_pid)` — the blocking NIF.
3. Rust runs `bash.exec_with_extensions(script, ⟨handler: h_pid⟩)`, threading the
   pid as a **per-execution extension** (bashkit's `ExecutionExtensions`, read by
   a builtin via `ctx.execution_extension::<T>()`).
4. When the NIF returns, Elixir tears `H` down.

### The round-trip

When a script runs `name args`, bashkit invokes `ElixirBuiltin::execute(ctx)`:

1. Read `h_pid` from `ctx.execution_extension`; read `args`, `stdin`, `env`.
2. Allocate a `req_id` (process-global `AtomicU64`); create a
   `tokio::sync::oneshot` channel; park the `Sender` in a global
   `Mutex<HashMap<u64, Sender<Reply>>>`.
3. Via `OwnedEnv`, send `{:bashkit_call, req_id, name, args, stdin, env}` to `H`.
4. `await` the receiver wrapped in `tokio::time::timeout(builtin_timeout)`.
5. `H` runs `builtins[name].(call_map)`, normalizes the return, and calls the
   `builtin_reply(req_id, stdout, stderr, exit_code)` NIF, which removes the
   sender from the table and `send`s the `Reply` into the oneshot.
6. The builtin wakes, builds an `ExecResult { stdout, stderr, exit_code }`,
   returns it. The command's output flows on as normal shell output.

**Async, not blocking.** Awaiting a `oneshot` (rather than `block_in_place` on a
sync channel) frees the tokio worker while the host thinks; only the outer
dirty-scheduler thread is pinned for the script's duration, which is inherent to
the synchronous `exec/2` API and unavoidable. Consequence (durable): bound
concurrency / pool sessions under load.

## The contract

A builtin is an **arity-1 function**. It receives one map:

```elixir
%{args: [String.t()], stdin: binary(), env: %{String.t() => String.t()}}
```

- `args` — command arguments, excluding the command name.
- `stdin` — piped input from the previous pipeline stage (`""` if none).
- `env` — the session's environment variables at call time.

It returns a **tagged** result (tagged tuples are the house style):

| Return | Becomes |
|--------|---------|
| `{:ok, iodata}` | stdout = iodata, stderr = "", exit = 0 |
| `{:error, iodata}` | stdout = "", stderr = iodata, exit = 1 |
| `%ExBashkit.Result{stdout:, stderr:, exit_code:}` | full control (the same struct `exec/2` returns) |
| anything else | contract violation → exit 1 + a clear stderr message |

## Failure model

A misbehaving host builtin must never corrupt or wedge the session.

- **Raises / bad-shape return** → `H` rescues and replies exit `1` + a stderr
  message (`name: builtin raised: …`). The script *continues*; it's a failed
  command, not a dead session.
- **Hangs** → a dedicated **back-call timeout** covers a handler that never
  replies: on expiry the builtin returns exit `124` + a stderr note, and `H` is
  killed on teardown. Default **30_000 ms**, overridable per session via
  `:builtin_timeout_ms` (a DB-query builtin may outlive a tight script timeout).
  - **Correction (caught in review):** bashkit *also* enforces its own execution
    `:timeout_ms` by wrapping the whole run in `tokio::time::timeout` and
    **dropping** the future on expiry. If that fires while a builtin is parked on
    the reply channel, our `execute` future is dropped mid-`await` — so the
    pending-call slot must be cleared on **drop**, not just on our own timeout
    path, or the parked sender leaks forever. A `PendingCleanup(req_id)` RAII
    guard held for the lifetime of `execute` handles every exit path (return,
    our timeout, and cancellation) idempotently with `builtin_reply`'s removal.
- **Reentrancy (hard rule)** → a builtin handler must **not** call `exec/2` on the
  *same* session; it would block on the session lock the in-flight exec holds.
  Calling a *different* session is fine. Documented loudly.

## API

`ExBashkit.Session.new/1` gains:

- `:builtins` — `%{name => arity-1 fun}`. Names are non-empty strings; values are
  arity-1 funs. Validated on the Elixir side (raise `ArgumentError` otherwise).
- `:builtin_timeout_ms` — positive integer, default `30_000`.

No change to `exec/2`'s signature for callers; it grows the internal handler-pid
plumbing only.

## Testing (TDD, offline, deterministic)

- A builtin that echoes `args` / `stdin` / `env` back as stdout.
- `{:error, …}` → exit 1 + stderr; `%Result{}` → full control / custom exit code.
- A raising handler → exit 1, session still usable afterward.
- Stdin piping: `echo hi | mybuiltin`.
- A builtin that calls a **different** session (allowed) — proves non-reentrant
  cross-session use works.
- Timeout: a deliberately slow handler with a tiny `:builtin_timeout_ms` → exit
  124; session usable afterward.
- Validation: non-string key, non-fun / wrong-arity value, bad timeout.

## Out of scope (deferred)

- **Dynamic Elixir-backed VFS** — next phase (6b), same bridge.
- **Streaming output** — builtins return a complete result; incremental
  `exec_streaming` output is a later refinement.
- Passing a richer context (cwd mutation, fs handle) to the Elixir builtin —
  start with read-only `args`/`stdin`/`env`.
