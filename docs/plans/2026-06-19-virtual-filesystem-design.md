# Phase 6b — Elixir-backed virtual filesystem (`:virtual_fs`)

Status: design approved 2026-06-19. Reuses the Phase 6 back-call bridge. Follows
the per-phase loop (TDD → gate → `superpowers:code-reviewer` → fold → ship).

## Goal

Mount an **Elixir-backed filesystem** at a vfs path: a script's reads and writes
under that path are serviced by host application code, so "files" can be
generated on demand or proxied to a real backing store (a DB, KV, an API). This
is the second consumer of the back-call bridge (after custom builtins) and the
reason the bridge was built first on a one-method surface.

Read **and** write are in scope (user decision). The contract is a **dual**,
Plug-style: a behaviour module is the primary form, a plain function is a
convenience — both normalize in the handler, so the Rust side is identical.

## Mounting & composition

`Session.new(virtual_fs: %{"/api" => spec})`, multiple mounts allowed. Each
`spec` becomes a Rust `ElixirFs` (a `bashkit::FileSystem` impl) mounted via
`Bash::mount(vfs_path, Arc::new(elixir_fs))` **after build** — composing with the
in-memory base, host `:mounts`, and `:limits`, exactly like any other mount.

**Path rooting:** bashkit's `MountableFs` strips the mount prefix, so the handler
receives paths **rooted at its mount**: vfs `/api/users/1.json` arrives as
`/users/1.json`; the mount root arrives as `/`.

## The contract (Elixir-side; the Rust bridge is agnostic to the shape)

### Behaviour — `ExBashkit.VirtualFs` (primary)

Callbacks take the per-mount `arg` (the `{module, arg}` state) first:

| Callback | Returns |
|----------|---------|
| `read(arg, path)` | `{:ok, iodata}` \| `{:error, reason}` |
| `write(arg, path, data)` | `:ok` \| `{:error, reason}` |
| `append(arg, path, data)` | `:ok` \| `{:error, reason}` |
| `mkdir(arg, path, recursive?)` | `:ok` \| `{:error, reason}` |
| `remove(arg, path, recursive?)` | `:ok` \| `{:error, reason}` |
| `list(arg, path)` | `{:ok, [name \| {name, :file\|:dir}]}` \| `{:error, reason}` |
| `stat(arg, path)` | `{:ok, %{type: :file\|:dir, size: n}}` \| `{:error, reason}` |

All `@optional_callbacks`. `use ExBashkit.VirtualFs` injects defaults: every
mutating/listing op defaults to `{:error, :enotsup}`, and **`stat` derives from
`read`** (a backend that implements only `read/2` gets working `cat`/`stat`/
`exists` for files for free — at the cost of fetching content to size it; a
backend that cares overrides `stat`). Registered as `{module, arg}` or a bare
`module` (arg defaults to `nil`).

### Function — convenience (inline / quick)

`virtual_fs: %{"/api" => fn request -> ... end}` — one arity-1 function,
pattern-matching on `request.op` (`:read | :write | :append | :mkdir | :remove |
:list | :stat`), with op-specific keys (`:data`, `:recursive`). Returns the same
tagged replies as the behaviour callbacks. A catch-all clause should return
`{:error, :enotsup}`.

### Errors

`reason` is an errno-style atom — `:enoent`, `:eacces`, `:eexist`, `:eisdir`,
`:enotdir`, `:enotsup` — or a string. Mapped Rust-side to a `std::io::Error`
(`NotFound`/`PermissionDenied`/`AlreadyExists`/`Unsupported`/`Other`) → bashkit
surfaces it as the command's filesystem error.

## Scope (bounded, like every phase)

**Forwarded to Elixir (7 ops):** read_file, write_file, append_file, mkdir,
remove, read_dir, stat.

**Derived/defaulted in Rust (no back-call), to bound the contract:**
- `exists` ← derived from `stat` (`Ok`→true, `NotFound`→false).
- the mount **root `/` stats as a directory** without a back-call, so the mount
  never looks broken during path resolution.
- `chmod` → silent `Ok(())` (meaningless on virtual files; avoids breaking
  scripts that chmod).
- `rename`, `copy`, `symlink`, `read_link` → `Err(enotsup)`. So `mv`/`cp`
  *across* a virtual mount are unsupported in this phase (documented; a later
  phase can forward them — same bridge).

## Mechanism — reuse + the one new piece

Identical to Phase 6: `spawn_blocking` for the panic-prone `OwnedEnv` send, an
`await`ed `oneshot`, the back-call timeout, and a `PendingCleanup` RAII guard for
cancellation. Two differences:

1. **No `Context` ⇒ a shared per-exec cell.** `FileSystem` methods get only
   `&Path` (no `execution_extension`), so the handler pid + timeout travel via a
   `Arc<Mutex<Option<CallTarget>>>` held on `SessionResource` and shared into
   every `ElixirFs`. `session_exec` sets it before the run and clears it after —
   safe because a session's execs are serialized by the `bash` mutex.
2. **Heterogeneous replies.** Builtins always reply with bytes; FS ops reply with
   bytes (read), unit (write/…), an entry list (read_dir), or metadata (stat). A
   new `fs_reply(req_id, reply)` NIF decodes a normalized tagged term into an
   `FsReply` enum, delivered through a separate `pending_fs_calls` table.

One handler process per `exec/2` services **both** builtin and FS back-calls
(seeded with both `:builtins` and `:virtual_fs`). Wire message:
`{:bashkit_fs, req_id, mount_path, op, path, data, recursive}`.

## Failure model (same as builtins)

A handler that raises, returns a bad shape, or exceeds `:builtin_timeout_ms`
yields an **error for that operation** (the command sees an FS error); the
session stays usable. No same-session reentrancy (the handler must not `exec/2`
the session whose script triggered the FS op).

## Testing (TDD, offline, deterministic)

- **fn form:** a map-backed `/kv` mount — `cat`/`echo >`/`ls`/`rm`/`stat` round-trip.
- **behaviour form:** the same backend as a `{module, arg}`, proving dispatch and
  the `use` defaults (implement `read` only → `cat` + `[ -f ]` work via derived
  `stat`; an un-implemented `write` → `enotsup`).
- **bare module** (arg `nil`).
- **errors:** `{:error, :enoent}` → "No such file or directory"; a write to a
  read-only backend → failure.
- **composition:** a virtual mount coexists with `:files`, host `:mounts`, and
  `:builtins` in one session; reads outside the mount are unaffected.
- **failure isolation:** a raising handler fails the op, session still usable;
  the cross-cancellation/leak guard covered as in Phase 6.
- **validation:** bad spec (not fn/module/{module,arg}), non-absolute/`"/"` path.

## Out of scope (deferred)

- `rename`/`copy`/`symlink`/`read_link` proxying (mv/cp across a virtual mount).
- Streaming reads/writes (whole-content per op for now).
- Per-op concurrency within one exec (back-calls serialize through the handler).
