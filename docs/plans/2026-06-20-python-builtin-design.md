# Phase 7 — A `python` builtin backed by ex_monty (shared-VFS)

**Status:** designed 2026-06-20. Supersedes PORTING.md Phase 7's "bashkit-native
interpreters" framing after the findings below.

Give a sandboxed bash session a real `python` command — `python script.py`,
`echo code | python`, `python -c "…"` — where the Python **shares the bash
session's filesystem**, so a file one step writes another step reads. Built
entirely on machinery we already ship; **no change to the bashkit dependency**;
opt-in by adding `ex_monty` to deps.

## Why not bashkit-native python (the original Phase 7 plan)

Two findings killed it:

1. **The pinned `bashkit 0.11.0` on crates.io has no `python` feature and no
   monty dependency at all.** (Verified: its `[features]` block is
   `bot-auth / git / http_client / interop / jq / logging / realfs /
   scripted_tool / sqlite / ssh / typescript` — no `python`.) The feature exists
   only in the unreleased `../bashkit` checkout, where `monty` is a **git dep**
   (`github.com/pydantic/monty`, tag `v0.0.18`). Enabling it would force our
   whole bashkit dependency onto a moving git source — a real supply-chain
   downgrade for a precompiled-NIF library.
2. Even once released, a Cargo feature is **compile-time** — it can't be gated on
   whether an Elixir library is present, and a precompiled NIF freezes it. It'd
   be "bake a Python interpreter into every download" or "python users build from
   source."

`sqlite` and `typescript` are **dropped** entirely (user decision 2026-06-20):
sqlite, if anyone wants it, is better served by a back-call to Elixir's own
SQLite; typescript is unwanted.

## The approach: python as an Elixir-defined builtin

We already have everything:

- **Custom builtins** (Phase 6): `Session.new(builtins: %{"python" => handler})`
  registers a virtual executable; invoking `python …` back-calls a per-`exec`
  Elixir handler process. Failure isolation, `:builtin_timeout_ms`, and the
  no-same-session-reentrancy rule already apply.
- **ex_monty** (sibling lib we control) runs Python as a pull-based sandbox:
  `ExMonty.Sandbox.run(code, opts)` compiles + runs to completion and returns
  `{:ok, value, captured_stdout}` | `{:error, reason}`. Python's filesystem/OS
  operations surface as effects serviced by an `:os` handler — a map
  `%{op_atom => fn args, kwargs -> result end}` (or a `handle_os/3` module).
- **Lock-free session FS NIFs** (Phase 3/6b): `Session.read_file/2` and
  `write_file/3` touch the session's FS `Arc` **without the bash lock**. That is
  the linchpin: the `python` builtin runs *inside* an `exec` (the bash lock is
  held), yet it can still read/write that same session's VFS because those
  primitives don't take the lock. No deadlock, no reentrancy-rule violation
  (we never call `exec/2`).

```
bash script:  curl … > /work/data.json   (bash, writes session VFS)
              python transform.py         (our builtin)
                └─ back-call → Elixir python handler
                     ├─ read transform.py from session VFS   (read_file, lock-free)
                     └─ ExMonty.Sandbox.run(source, os: session_fs_handler)
                          every Path.read_text()/write_text() Python does
                          → :os_call → handler routes to session read_file/write_file
                     → returns captured stdout
              wc -l /work/out.csv          (bash, reads what python wrote)
```

Python and bash share one filesystem because the `:os` handler **is** a window
onto the bash session VFS. This is the mirror image of the `:virtual_fs` feature:
there, Elixir backs a *bash* filesystem; here, Elixir backs a *Python*
filesystem with the bash session's contents.

## Gating / opt-in surface

`ex_monty` is an **optional** dependency (`{:ex_monty, "~> …", optional: true}`).
Python is enabled per session by an explicit flag, which *requires* the library
(fail-fast, not silent magic):

```elixir
Session.new(python: true)                 # registers a "python" builtin
Session.new(python: [name: "python3"])    # alias / config
```

- `python: true` registers a `"python"` builtin (and we may also alias
  `"python3"`). If `ex_monty` isn't loadable, `new/1` raises a clear
  `ArgumentError` ("`:python` requires the optional `:ex_monty` dependency; add
  `{:ex_monty, …}` to your deps") — `Code.ensure_loaded?(ExMonty)` is the gate.
- Default `python: false`. No surprise commands appear.
- Implemented in terms of `:builtins`: under the hood `python: true` merges a
  `%{"python" => &ExBashkit.Python.run/1}` entry, so power users can also wire it
  manually with custom options, and it composes with their own `:builtins`.

Rationale: explicit opt-in beats auto-enable-on-presence — the same code runs
with or without the optional dep in the tree, and an unexpected in-band `python`
is exactly the kind of capability a sandbox author wants to declare, not inherit.

## The session FS host API (small prerequisite)

The `:os` handler needs to service the full pathlib/`os` surface against the live
session VFS. `Session` currently exposes only `read_file/2` and `write_file/3`.
We add a few more **lock-free** host primitives (each a thin NIF over the session
`fs` `Arc`, mirroring `session_read_file`/`session_write_file` — no bash lock,
`block_on` the async `FileSystem` trait method):

| New primitive                     | bashkit FS call        | Serves Python op(s)              |
|-----------------------------------|------------------------|----------------------------------|
| `session_stat(s, path)`           | `fs.stat`/metadata     | `stat`, `exists`, `is_file`, `is_dir` |
| `session_list_dir(s, path)`       | `fs.read_dir`          | `iterdir`                        |
| `session_mkdir(s, path, parents)` | `fs.mkdir`             | `mkdir`                          |
| `session_remove(s, path, recur)`  | `fs.remove`            | `unlink`, `rmdir`                |
| `session_rename(s, from, to)`     | `fs.rename`            | `rename`                         |

`read_text`/`read_bytes`/`write_text`/`write_bytes` use the existing
`read_file/2` + `write_file/3`. `append_text`/`append_bytes` = read-concat-write
in the handler (or a future `session_append`). These primitives are independently
useful (host introspection of a session's FS) and small.

> **Scope lever:** a faster v1 could expose *only* `read_text`/`write_text`/
> `exists` (all derivable from the two existing primitives) and defer
> `mkdir`/`iterdir`/`stat`/`rename`. But a generated script doing
> `Path("/out").mkdir()` failing is the same silent-footgun-for-LLMs we're
> avoiding, so the recommended v1 is the full table above.

## The `:os` handler (modeled on `ExMonty.PseudoFS`)

`ExMonty.PseudoFS` is a complete reference handler for these ops against an
in-memory map. We build `ExBashkit.Python.SessionFs` — the **same dispatch,
routed to the session** — so the contract (arg shapes, return encodings) is
exactly what monty expects:

| Python                  | os_call        | handler → session                          | returns |
|-------------------------|----------------|--------------------------------------------|---------|
| `Path.read_text()`      | `:read_text`   | `read_file` → utf8                         | `{:ok, str}` / `{:error, :file_not_found_error, …}` |
| `Path.read_bytes()`     | `:read_bytes`  | `read_file`                                | `{:ok, {:bytes, bin}}` |
| `Path.write_text(d)`    | `:write_text`  | `write_file`                               | `{:ok, byte_size}` |
| `Path.write_bytes(d)`   | `:write_bytes` | `write_file`                               | `{:ok, byte_size}` |
| `Path.exists/is_file/is_dir` | `:exists`/`:is_file`/`:is_dir` | `session_stat` | `{:ok, bool}` |
| `Path.stat()`           | `:stat`        | `session_stat` → StatResult named-tuple    | `{:ok, {:named_tuple, "StatResult", …}}` |
| `Path.iterdir()`        | `:iterdir`     | `session_list_dir`                         | `{:ok, [{:path, child}, …]}` |
| `Path.mkdir()`          | `:mkdir`       | `session_mkdir` (honor `parents`/`exist_ok`)| `{:ok, nil}` |
| `Path.unlink/rmdir`     | `:unlink`/`:rmdir` | `session_remove`                       | `{:ok, nil}` |
| `Path.rename(t)`        | `:rename`      | `session_rename`                           | `{:ok, {:path, t}}` |
| `Path.resolve/absolute` | `:resolve`/`:absolute` | identity                           | `{:ok, path}` |
| `os.getenv/os.environ`  | `:getenv`/`:get_environ` | session `:env` snapshot          | `{:ok, val}` |

Path args arrive as `{:path, p}` or a bare binary (PseudoFS's `extract_path`).
Errors use Python exception atoms (`:file_not_found_error`, `:os_error`, …) so
Python sees real `FileNotFoundError`/`OSError`.

## Effect posture (v1)

- **Filesystem:** routed to the session VFS (above).
- **Env:** `getenv`/`get_environ` read the session's `:env` (read-only).
- **Everything else default-denied.** Any os_call not in the handler map →
  `ExMonty.Sandbox` returns `{:error, :os_error, "… not permitted"}` →
  `OSError` in Python. No network (monty has no implicit sockets; we wire no
  network functions), no clocks unless asked.
- **Future:** let Python inherit the session's `:allow_net` by wiring an HTTP
  external function; surface `datetime_now`/`date_today` if a session opts in.

## Source, argv, output, errors

- **Source:** the builtin handler inspects `args`/`stdin`:
  - `python <path>` → `read_file(session, path)` (a real VFS read; missing file →
    exit 1, "can't open file").
  - `python -c "<code>"` → inline.
  - `python` with piped `stdin` → stdin is the program.
  - bare `python` with no stdin → error (no REPL).
- **argv:** `python script.py a b` should give `sys.argv == ["script.py","a","b"]`,
  but **this is deferred for v1.** Investigated 2026-06-20: monty (pydantic's,
  pinned git rev — *not* ex_monty) has no `sys.argv` and no host hook to inject
  module attributes; its modules have no `__dict__`, so even a `import sys;
  sys.argv = [...]` preamble is rejected (`'module' object has no attribute
  'argv' and no __dict__ for setting new attributes`). Real `sys.argv` therefore
  needs a **monty fork**, out of scope for v1. Documented gap: argparse-style
  scripts are limited; inline `-c` and stdin still work. `python script.py` works,
  but the script can't read its trailing arguments.
- **stdout:** `ExMonty.Sandbox.run/2`'s third return element is captured
  `print()` output → the builtin's stdout (exit 0).
- **errors:** `{:error, reason}` (compile error, uncaught exception, denied
  effect, limit) → builtin stderr + exit 1, formatting monty's traceback. (Map
  `sys.exit(n)` to exit `n` if monty surfaces it; else exit 1. Refine later.)
- **limits:** the run is already bounded by `:builtin_timeout_ms` at the bash
  back-call layer; additionally pass `ExMonty` `:limits`
  (`max_duration_secs ≈ builtin_timeout_ms/1000`, plus monty's instruction/alloc
  caps) so a hot loop is killed inside Python too.

## Failure isolation (inherited)

The `python` builtin is an ordinary back-call handler: a raising/looping/denied
Python run fails **only that command** (exit 1 / timeout 124), never the session;
the session stays usable for the next `exec`. Concurrent sessions are isolated
(each has its own handler + FS `Arc`).

## ex_monty / monty changes (investigated 2026-06-20)

**v1 needs no ex_monty changes** — `ExMonty.Sandbox.run/2` with an `:os` map
handler already drives the whole bridge. The candidate enhancements turned out to
be monty-level or unnecessary:

1. **`sys.argv`** — needs a **monty fork** (not ex_monty): monty has no `sys.argv`
   and no module-attr injection hook; modules have no `__dict__` so a preamble
   can't set it (verified). Deferred; fork is a future option if demanded.
2. `append_text`/`append_bytes` — serviced in our bridge (read-concat-write or a
   future `session_append`), no ex_monty change.
3. `open()` file objects (stateful handles) — even `PseudoFS` doesn't implement
   them. **Deferred**: v1 supports `pathlib.Path` I/O (what generated code / LLMs
   emit); `open()` documented unsupported.
4. (Later) upstream a generic "external FS handler" protocol into ex_monty so the
   route-to-host pattern is reusable beyond ex_bashkit.

## Test plan (TDD)

- `python -c "print(1+1)"` → stdout `2`, exit 0.
- `echo 'print("hi")' | python` (stdin program) → `hi`.
- Shared VFS read: bash writes `/work/in.txt`, `python -c
  'print(open... )'`/`Path('/work/in.txt').read_text()` sees it.
- Shared VFS write: Python `Path('/work/out.txt').write_text("x")`, then bash
  `cat /work/out.txt` → `x`.
- Round-trip pipeline: `echo data > /f; python transform.py; cat /out`.
- Missing file → Python `FileNotFoundError`, builtin exit 1, session still usable.
- `mkdir`/`iterdir`/`stat`/`unlink`/`rename` each round-trip against the VFS.
- Denied effect (e.g. a network attempt / unhandled os_call) → exit 1, isolated.
- Timeout: an infinite loop is killed by `:builtin_timeout_ms`; session survives.
- `python: true` without `ex_monty` loadable → `new/1` raises a helpful error.
- Composition: `python` coexists with `:builtins`, `:virtual_fs`, snapshot.

## Deliverables

New `ExBashkit.Python` (builtin entry) + `ExBashkit.Python.SessionFs` (`:os`
handler); the extra session FS NIFs + Elixir wrappers; `:python` option on
`new/1`; README "Python" section; CHANGELOG; `examples/python.exs` (needs
`ex_monty` in the example's deps); tests gated on `ExMonty` availability.

## Out of scope

- bashkit-native python / sqlite / typescript (see top).
- `open()` file-handle semantics; full `sys.argv` (pending ex_monty); Python
  network/clock effects (future, opt-in).
- Persisting Python state across `python` invocations — each call is a fresh
  ex_monty run (the *files* persist via the shared VFS; in-memory Python globals
  do not, exactly like separate `python` process invocations in a real shell).
