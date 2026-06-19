# Phase 8 — Snapshot / resume

**Status:** designed 2026-06-20. Implements PORTING.md Phase 8.

Persist a running session's state to bytes and reload it later — in the same
process, after a restart, or on another node. bashkit gives us the primitive;
ExBashkit marshals it and pins down the one thing the bytes *don't* carry.

## What bashkit provides (pinned `=0.11.0`)

`bashkit::Bash` exposes a high-level snapshot API (`src/snapshot.rs`):

- `snapshot() -> Result<Vec<u8>>` / `snapshot_with_options(SnapshotOptions)` —
  capture **shell state** (vars, env, cwd, arrays, aliases, traps, functions)
  **+ in-memory VFS contents**, serialized as
  `[32-byte SHA-256 digest][JSON]`. The digest detects *accidental* corruption
  only — it is **not** a secret (anyone with the source can forge it).
- `restore_snapshot(&mut self, &[u8]) -> Result<()>` — load state **into an
  existing instance, preserving that instance's configuration** (limits,
  builtins, mounts, filesystem type). Validates everything that can fail
  *before* mutating, so a bad snapshot can't half-restore.
- Keyed variants — `snapshot_to_bytes_keyed(key)` /
  `restore_snapshot_keyed(data, key)` — use `HMAC-SHA256(key, payload)` instead
  of the public tag. **This is the one to use when snapshots cross a trust
  boundary** (network, shared storage, untrusted upload): a wrong key or
  tampered bytes are *rejected*, not trusted.
- `SnapshotOptions { exclude_filesystem, exclude_functions }` — shell-only or
  AST-free snapshots.
- `from_snapshot(&[u8]) -> Self` also exists but **resets config to defaults**.
  We do **not** use it (see below).

`SNAPSHOT_VERSION` is embedded; `from_bytes` rejects a mismatched version.

## The load-bearing constraint: config is *not* in the snapshot

A snapshot carries shell state + in-memory FS **contents only**. It does **not**
carry:

- `:builtins` — those are live Elixir handler closures, registered into the
  Rust `Bash` at `session_new` and serviced by a per-exec handler process.
- `:virtual_fs` backends — likewise live Elixir processes; their *content*
  lives in Elixir, never in bashkit. (`MountableFs::vfs_snapshot` delegates to
  the **root** in-memory fs only — mounted filesystems are skipped by design.)
- `:mounts` (host directories), `:limits`, `:env`/`:cwd`/`:username`/`:hostname`
  builder config, `:allow_net`/`:block_private_ips`.

**Therefore resume is inherently two-step: rebuild a session with the same
capabilities, then load the saved state into it.** This is exactly what
`restore_snapshot` (config-preserving) is for, and why we avoid `from_snapshot`
(config-dropping). It also means restoring a snapshot taken from a session that
*used* a `/kv` virtual mount into a new session that re-declares the same `/kv`
mount Just Works — the backend is re-attached live; only the shell + in-memory
FS travel in the bytes.

We document this loudly. It is not a limitation to paper over — it's the
honest shape of a push-based interpreter whose effects are live Elixir.

## Elixir API

Two functions (chosen over a `:snapshot` option on `new/1`: keyed snapshots
cross trust boundaries, so a tampered/wrong-key restore must be a recoverable
`{:error, _}`, and `new/1` raises on bad input):

```elixir
@spec snapshot(t(), keyword()) :: {:ok, binary()} | {:error, String.t()}
# opts: :key (binary -> HMAC-keyed), :exclude_filesystem (bool),
#       :exclude_functions (bool)
{:ok, bytes} = Session.snapshot(session)
{:ok, bytes} = Session.snapshot(session, key: secret, exclude_functions: true)

@spec restore(t(), binary(), keyword()) :: {:ok, t()} | {:error, String.t()}
# opts: :key (binary — must match the key the snapshot was taken with)
target = Session.new(builtins: same, virtual_fs: same, limits: same)
{:ok, ^target} = Session.restore(target, bytes)
{:error, msg} = Session.restore(target, tampered)   # or wrong/missing key
```

`restore/3` mutates the target session's interpreter **in place** (the resource
is a single-logical-owner `Mutex<Bash>`) and returns `{:ok, session}` — the same
struct — for chainability. Capabilities configured on `target` are preserved;
only shell + in-memory FS state are overwritten.

Keying is all-or-nothing and symmetric: bytes taken with `:key` **must** be
restored with the same `:key`; plain bytes must be restored without one.
Mixing them is an `{:error, _}` (HMAC / digest mismatch), surfaced from bashkit.

## NIF surface (marshal-only, no vendored logic)

```rust
#[rustler::nif(schedule = "DirtyCpu")]   // sync, but VFS can be large
fn session_snapshot(env, session, exclude_filesystem: bool,
                    exclude_functions: bool, key: Option<Binary>) -> Term
//   -> {:ok, binary} | {:error, message}

#[rustler::nif(schedule = "DirtyCpu")]
fn session_restore(env, session, data: Binary, key: Option<Binary>) -> Term
//   -> :ok | {:error, message}
```

Both lock `session.bash` with the established poison-recovery
(`unwrap_or_else(|p| p.into_inner())`). `snapshot` builds `SnapshotOptions` and
calls `snapshot_with_options` / `snapshot_to_bytes_keyed_with_options`;
`restore` calls `restore_snapshot` / `restore_snapshot_keyed`. `key: None` ⇒
unkeyed path, `Some` ⇒ keyed. Errors stringify bashkit's `Error` into the
`{:error, message}` we already use everywhere. No async, no runtime needed —
these are synchronous bashkit calls — but `DirtyCpu` keeps a large
serialize/deserialize off the normal schedulers.

## Test plan (TDD, write red first)

- Round-trip a shell var across a fresh same-config session.
- Round-trip in-memory VFS contents (script-written file survives).
- Round-trip a shell **function** (default includes functions).
- `exclude_filesystem: true` — var survives, file does not.
- `exclude_functions: true` — var survives, function does not.
- Keyed round-trip succeeds with the matching key.
- Wrong key, missing key (keyed bytes via plain restore), and keyed restore of
  plain bytes all return `{:error, _}` — session stays usable.
- Tampered bytes (flip a byte) → `{:error, _}`.
- Garbage / too-short bytes → `{:error, _}`.
- **Capability preservation:** snapshot from a plain session; restore into a
  session built *with* a `:builtin` — the var loads **and** the builtin still
  runs.
- Restore into the *same* session reverts later mutations (in-place).
- `restore/3` returns `{:ok, session}` and the returned struct is usable.

## Docs / deliverables

README "Snapshot & resume" section, CHANGELOG `[Unreleased]`,
`examples/snapshot.exs` (set state → snapshot → "restart" by building a fresh
session → restore → observe state; show the keyed cross-trust-boundary form).
Update PORTING/HANDOFF/phase-status memory.

## Out of scope (note, don't build)

- Pause **mid-effect**. Snapshots are taken at command boundaries; a parked
  back-call (builtin / virtual_fs) is not a resumable point. This matches the
  handoff's "Snapshot is NOT a pause-mid-effect primitive."
- Persisting `:virtual_fs` / host-mount contents — those live outside bashkit.
- Auto-rebuilding capabilities from the snapshot — bytes don't carry them.
