# ExBashkit Porting Playbook

How to grow this scaffold into a complete, community-grade Elixir wrapper around
bashkit. It distills the lessons from the sibling project **ExMonty** (which
wraps the `monty` Python interpreter the same way) and lays out a staged plan
for the parts that are genuinely different here — chiefly bashkit's `async` API
and its "configure-then-run" effect model.

Read this top-to-bottom once, then work the phases in order. Each phase is
shippable on its own.

---

## 0. The shape of the thing

ExBashkit is a thin **Rustler NIF** over the `bashkit` crate, distributed as a
**precompiled binary** via `rustler_precompiled` so end users need no Rust
toolchain. The Elixir side owns the ergonomics (structs, the public API, the
eventual LLM-tool helpers); the Rust side is a faithful, minimal bridge.

```
lib/ex_bashkit.ex            # stateless exec/1
lib/ex_bashkit/session.ex    # ExBashkit.Session — sessions, VFS, mounts, limits
lib/ex_bashkit/native.ex     # RustlerPrecompiled config + NIF stubs
lib/ex_bashkit/result.ex     # %ExBashkit.Result{}
native/ex_bashkit/src/lib.rs # #[rustler::nif] fns + shared tokio runtime
```

**Golden rule (carried from ExMonty):** vendor *no* execution logic on the
Elixir side. Every semantic — what a builtin does, how the VFS behaves, what a
limit means — comes from bashkit. We only marshal data across the boundary. When
bashkit changes, we should mostly be updating encodings, not behavior.

---

## 1. Lessons inherited from ExMonty

These cost real time on ExMonty. Honor them here.

### Rustler 0.37 specifics
- NIFs are auto-discovered from `#[rustler::nif]`; `rustler::init!("Elixir.ExBashkit.Native")` takes only the module name (no fn list).
- Resources: `#[rustler::resource_impl] impl Resource for T {}`. Wrap them in `ResourceArc<T>`.
- For any bashkit API that **consumes `self`** (e.g. a snapshot's `resume`),
  store it as `Mutex<Option<T>>` inside the resource and `.take()` on use. Once
  taken, return a clean "already consumed" error. (ExMonty does exactly this for
  `Snapshot`/`FutureSnapshot`.)
- You cannot call Erlang functions from inside a NIF in 0.37. Anything that
  needs Elixir's help must be modeled as *data returned to Elixir*, which Elixir
  acts on and passes back — see the custom-builtins phase.

### The precompiled-NIF release dance (the part everyone gets wrong)
- `lib/ex_bashkit/native.ex` downloads a prebuilt NIF whose checksum must be in
  `checksum-Elixir.ExBashkit.Native.exs`. **That file starts empty and is
  regenerated *after* a release exists.** The full ordering lives in
  [`UPDATE_PROCEDURE.md`](UPDATE_PROCEDURE.md), but the trap is:
  1. tag `vX.Y.Z` → `release.yml` builds the 4 NIFs and creates the GitHub release,
  2. **then** `mix rustler_precompiled.download ExBashkit.Native --all --print`
     downloads them and writes the checksum file,
  3. commit the checksum file, **then** `mix hex.publish`.
- The download task has a **chicken-and-egg**: it must *compile* `native.ex`
  first, which tries to fetch a NIF that isn't published yet. Run it with
  `EXBASHKIT_BUILD=1` so the local build satisfies compilation, e.g.
  `EXBASHKIT_BUILD=1 mix rustler_precompiled.download ExBashkit.Native --all --print`.
- Keep the NIF ABI version (`nif-2.15`) in `release.yml` in sync with rustler.

### Pin exact versions, never a moving ref
- bashkit is on crates.io, so pin `bashkit = "=0.11.0"` (exact). Bump
  deliberately via the update procedure. (ExMonty had to pin a 40-char git hash
  because monty isn't published; we have it easier.)

### CI gates that catch the common breakage
- `mix format --check-formatted`, `cargo fmt --check`,
  `cargo clippy -- -D warnings`, `mix compile --warnings-as-errors`, `mix test`.
- CI builds the NIF from source (`EXBASHKIT_BUILD=1`) rather than downloading.

### Docs are part of "done"
- Every new public function/field gets a moduledoc + `@spec` + a doctest or
  test. Every new capability gets a README section and a CHANGELOG entry. On
  ExMonty, doc drift was the easiest thing to forget.

---

## 2. What's genuinely different about bashkit

### a) `bashkit::Bash::exec` is `async` (tokio)
monty was synchronous; bashkit is not. The bridge (already in the skeleton):

- Host **one** process-wide `tokio` runtime via `OnceLock` and `block_on` it
  from inside a **dirty** NIF (`schedule = "DirtyCpu"`, or `DirtyIo` once the
  network feature can actually block on sockets). Do **not** build a runtime per
  call.
- Multi-thread + `enable_all` is the safe default and is *required* by the
  `sqlite` feature.
- Never `block_on` from a regular (non-dirty) NIF — you'll stall a scheduler.

### b) bashkit's effect model is "configure-then-run", not "yield-per-effect"
This is the deepest conceptual difference and it changes how host mediation
works:

- **ExMonty/monty** is *pull-based*: the run loop yields each OS call back to
  Elixir, which adjudicates it and resumes. The host sees every effect.
- **bashkit** is *push-based*: you configure capabilities up front on the
  `Bash::builder()` — which virtual filesystem, which network allowlist, which
  custom builtins — then let the whole script run. The host grants, then steps
  back.

Practical consequence: most "host control" is expressed as **builder
configuration** (phases 3–5) plus **custom builtins** (phase 6), not as a
per-effect run loop. If you want monty-style per-effect mediation, that lives
inside a *custom builtin* that calls back into Elixir.

> ⚠️ **This is the central architectural risk of the port — do not gloss it.**
> ExMonty's serialization and resource patterns transfer directly. Its
> *effect-mediation* pattern does **not**, because of async + push execution:
>
> - monty turns each effect into a **return value** (`{:os_call, ...}`) and
>   resumes via a fresh NIF call. Nobody holds a scheduler while the host
>   thinks; it's trivially snapshot/resume-across-nodes.
> - bashkit services effects **inside** the `async` run. A host callback means an
>   `async` builtin must `send` to an Elixir pid and **block awaiting a reply on
>   a channel — mid-`block_on`, on the dirty scheduler stack.** Rust → Elixir →
>   Rust round-trip in the middle of execution.
>
> Three consequences to design around:
> 1. **Inversion of control** at the callback boundary (deadlock/lifetime
>    hazards; far hairier than `resume/2`).
> 2. **A scheduler is pinned for the whole script**, including time spent waiting
>    on Elixir — the finite dirty pool can starve under concurrent sandboxes that
>    call back. Bound concurrency / pool the sessions.
> 3. **Cancellation is hard**: a running dirty NIF can't be cleanly killed. Rely
>    on bashkit's internal limits + a tokio timeout, not BEAM `Task.shutdown`.
>
> `Snapshot` does **not** rescue this — it saves whole sessions at command
> boundaries, it is not a pause-mid-effect primitive.
>
> **Design stance:** don't fight bashkit into monty's shape. Pre-grant
> capabilities up front (VFS contents, allowlist, env) to cover the 80% case with
> zero callbacks. Quarantine the channel-bridge to phase 6, and build/prove that
> machinery first via **streaming output** (phase 9's simpler cousin) before
> interactive builtins. For the simple `exec` path, async stays invisible.

### c) Feature flags gate large optional subsystems
From bashkit's `Cargo.toml`:
- `default = ["bash_tool"]` — the Rust LLM-tool wrapper. We build our tool
  contract on the Elixir side, so we start `default-features = false`.
- `python = ["dep:monty"]` — **monty is a git dep upstream, unavailable from the
  crates.io build.** Enabling `python` from the registry won't work; it needs a
  git source for bashkit (or wait for monty on crates.io). Document loudly.
- `sqlite` — pulls Turso (multi-MB) and needs `tokio/rt-multi-thread`; also
  double-gated at runtime by `BASHKIT_ALLOW_INPROCESS_SQLITE=1`.
- `typescript`, `git`, `ssh`, `http_client`, `jq` — each opt-in.
- Adding a feature roughly multiplies build time. Add them per-phase, behind
  documented mix/env switches, not all at once.

### d) Build size & time
bashkit is ~150k LOC plus heavy deps. Expect slow first builds. Lean on
`Swatinem/rust-cache` (release) and the cargo cache (CI). Keep the default
feature set minimal so most users get fast precompiled downloads anyway.

### e) bashkit has `Snapshot` / `SnapshotOptions`
Pause/resume *is* possible (phase 8), and serialization patterns from ExMonty's
`serialization.rs` (postcard dump/load behind a resource) transfer directly.

---

## 3. Staged plan

Each phase: implement the NIF(s), add the Elixir API + struct, write tests
(`EXBASHKIT_BUILD=1 mix test`), update README + CHANGELOG, keep CI green.

> **Status (Phases 1–6 shipped to `master`, CI green; 98 tests).** Everything
> below the line is built. The per-phase loop that's working: TDD (write the
> failing test first) → implement → full gate (`mix test` + `mix format` +
> `cargo fmt` + `cargo clippy -D warnings`) → dispatch the `superpowers:code-reviewer`
> subagent → fold fixes → commit straight to `master` → watch CI. The reviewer
> has earned its keep every phase (caught the `bash.fs()` layering bug, the mount
> silent-skip, the limits overflow-revert, the trivially-passing network tests,
> the builtin pending-call leak + exit-code overflow crash). **Hex publish is
> deferred until the whole port is done** (user publishes). All public surface
> lives on `ExBashkit` (`exec/1`) and `ExBashkit.Session`. rustler is on 0.38
> (Rust + Elixir aligned); `release.yml`'s `nif-2.15` artifact name stays valid
> on OTP 27 but re-verify it at release time.

### Phase 1 — Stateless `exec/1` ✅
Done. `v0.1.0` tagged: GitHub release + 4 precompiled NIFs + checksum file all
verified end-to-end (only `mix hex.publish` itself is unexercised, by choice).

### Phase 2 — Persistent sessions & state ✅
Done. `ExBashkit.Session` = `ResourceArc<Mutex<Bash>>` (opaque `%Session{ref}}`),
`new/1` + `exec/2` thread state across calls. Builder options decoded Elixir-side:
`:env` (map/keyword), `:cwd`, `:username`, `:hostname`. The `exec` lock recovers
from poisoning (`into_inner`) so a bashkit panic can't brick a session.

### Phase 3 — Virtual filesystem ✅
Done. `Session.new(files: %{...})` seeds the in-memory FS; `write_file/3` +
`read_file/2` give the host access to the FS scripts use.
- **Store the interpreter's real FS handle** (`bash.fs()` *after* `build()`) —
  it's a `MountableFs` layered over the in-memory base, NOT a raw `InMemoryFs`.
- Host mounts: `Session.new(mounts: [{vfs, host, mode}], allowed_mount_paths: …)`.
  **Only `:read_only` / `:read_write`** — bashkit has no real-FS overlay mode, so
  `:overlay` was dropped ("only support what bashkit does"). **No `ExBashkit.Mount`
  resource / lease machinery** — bashkit is push-based, so mounts are plain builder
  config at session creation. This is the big simplification vs ExMonty's pull-based
  lease/checkout/drive design; don't reintroduce it. bashkit owns all
  escape/canonicalization/sensitive-path checks; we surface *refused* mounts (which
  bashkit silently skips) via a post-build `fs.exists(vfs)` probe → `{:error, _}`.

### Phase 4 — Resource limits ✅
Done. `Session.new(limits: [...])` decodes a map onto `ExecutionLimits` via
`builder.limits()`. Keys: `:max_commands`, `:max_loop_iterations`,
`:max_total_loop_iterations`, `:max_function_depth`, `:max_input_bytes`,
`:timeout_ms`. All produce `{:error, _}` on breach (per-script; counters reset
each `exec`). A value past `usize::MAX` means "unlimited" (saturates).
- **Deferred:** output-byte caps (`max_stdout_bytes`/`max_stderr_bytes`) — they
  *truncate* rather than error, so exposing them well means adding
  `stdout_truncated`/`stderr_truncated` to `%ExBashkit.Result{}` (which changes the
  result tuple and breaks the full-struct doctests). A small, self-contained
  follow-up when wanted.

### Phase 5 — Network allowlist ✅
Done. `Session.new(allow_net: ["https://api.example.com"] | :all)` maps to
bashkit's `NetworkAllowlist` (default-deny; matches scheme/host/port/path-prefix;
no redirects). `:block_private_ips` (default `true`) is bashkit's SSRF/private-IP
guard. `http_client` (reqwest + rustls) is **baked into the shipped NIF** (user
call) — declared as *our own* default Cargo feature `http_client =
["bashkit/http_client"]` so the `#[cfg(feature = "http_client")]` gates are real
(a bare `features = ["http_client"]` on the dep would NOT define a cfg for our
crate — the gates would be dead and `.network()` never called; the first cut hit
exactly this, caught by a failing loopback test). bashkit installs the `ring`
crypto provider itself (idempotent), so we do nothing there. `session_exec` →
`DirtyIo` (a networked script blocks on a socket); stateless `exec/1` stays
`DirtyCpu` (no allowlist → can't block). Network tests use an in-test loopback
`gen_tcp` server so the deny/allow paths are proven offline against a *reachable*
host (a non-resolving hostname would make a "blocked" assertion pass trivially —
the recurring trap).

### Phase 6 — Elixir-defined virtual executables (custom builtins) ✅
Done. `Session.new(builtins: %{"name" => fn call -> ... end})` registers virtual
executables a script invokes as `name args…`. The closures live on the Elixir
side; Rust registers one `ElixirBuiltin` per *name* and, on invocation, does the
**back-call**: park a `tokio::oneshot` in a global `req_id`-keyed table, send
`{:bashkit_call, req_id, name, args, stdin, env}` to a per-exec **handler
process**, `await` the reply (an `await`, not `block_in_place` — frees the tokio
worker). A `builtin_reply` NIF pushes the result back. Contract: `{:ok, io}` |
`{:error, io}` | `%Result{}`; raise/bad-shape/timeout → exit 1 (124) + stderr,
session stays usable. Design + the load-bearing details: **`docs/plans/2026-06-19-custom-builtins-design.md`**.

Hard-won specifics (don't re-derive):
- `OwnedEnv::send_and_clear` **panics on a BEAM-managed thread**; the builtin
  future is polled on the dirty-scheduler thread (via `block_on`), so the send
  goes through `tokio::task::spawn_blocking` (a non-VM thread).
- The handler pid rides per-exec as a bashkit `ExecutionExtensions` value, read
  via `ctx.execution_extension::<CallTarget>()` — that's how a builtin registered
  once at build time finds *this* exec's reply target.
- **Cancellation leak (reviewer-caught):** bashkit enforces its own `:timeout_ms`
  by wrapping the run in `tokio::time::timeout` and **dropping** the future. A
  builtin parked mid-`await` is dropped, so the table slot must be freed on
  *drop* — a `PendingCleanup(req_id)` RAII guard, not just the explicit paths.
- **exit_code is masked to a byte** Elixir-side (`Bitwise.band(code, 0xFF)`): the
  reply NIF takes `i32`, so an out-of-range `%Result{exit_code}` would otherwise
  raise in the (linked) handler and kill the caller.
- **No reentrancy:** a builtin must not `exec/2` the *same* session (it holds the
  lock). A *different* session is fine. The back-call timeout breaks an accidental
  same-session deadlock; it doesn't permanently pin a thread.
- Handler process is `spawn_link`ed then `unlink`+`:kill`ed on teardown (in an
  `after`) — orphan-safe if the caller dies, and the kill never reaches the caller.

### Phase 6b — Dynamic Elixir-backed filesystem (next, reuses the bridge)
`FileSystem` is a trait with `async` `read_file`/`write_file`/`read_dir`/`exists`/
`mkdir`/… Implement a backend that proxies to Elixir so files are generated on
demand. Reuses the exact back-call machinery from Phase 6 (the `req_id` table,
`builtin_reply`-style delivery, per-exec handler pid, `PendingCleanup`) — but
across ~6 methods on the FS hot path, so mind per-call cost and the same
no-reentrancy rule. Required feature, just sequenced after builtins.

### Phase 7 — Optional embedded interpreters
- `sqlite` (Turso), `typescript` (ZapCode), `python` (monty — **git-dep
  caveat**, see §2c). Each behind a mix config flag + cargo feature. Document the
  build-cost and the runtime gates (`BASHKIT_ALLOW_INPROCESS_SQLITE`).
- Note: enabling `python` makes ExBashkit a *superset* of ExMonty's Python
  surface (but without monty's fine-grained per-effect mediation).

### Phase 8 — Snapshot / resume
- `Snapshot`/`SnapshotOptions` → postcard dump/load behind a resource. Reuse
  ExMonty `serialization.rs` patterns. Enables pausing a long script and
  resuming later / on another node.

### Phase 9 — LLM tool contract helpers
- An `ExBashkit.Tool` module that emits a JSON schema + system-prompt text and
  parses tool calls — the Elixir analogue of bashkit's `BashTool`. This is what
  makes it drop-in for agent frameworks.

---

## 4. Definition of done (per phase and overall)

- [ ] NIF stubs in `native.ex` match the `#[rustler::nif]` fns exactly.
- [ ] Public functions have moduledocs, `@spec`s, and doctests/tests.
- [ ] `EXBASHKIT_BUILD=1 mix test` green; `cargo fmt`/`clippy` clean.
- [ ] README capability section + CHANGELOG `[Unreleased]` entry.
- [ ] An `examples/` script demonstrating the new capability end-to-end.
- [ ] No vendored execution logic — semantics come from bashkit.

When in doubt, open the ExMonty repo next door and copy the proven shape.
