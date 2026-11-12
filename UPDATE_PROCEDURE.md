# ExBashkit Update Procedure

Run this periodically to pull upstream bashkit changes into ExBashkit.

ExBashkit pins an **exact** bashkit version in `native/ex_bashkit/Cargo.toml`
(`bashkit = "=0.21.0"`). Unlike monty (git-only), bashkit is published to
crates.io, so we track **released versions**, not a moving branch.

**Track stable releases.** Target the latest `0.x.y` on crates.io unless the
user explicitly asks to chase a git revision for an unreleased fix.

---

## Phase 1: Assess

### 1.1 Find the latest released version

```bash
cargo search bashkit          # shows the latest published version
# or check https://crates.io/crates/bashkit
```

Note the current pin:

```bash
grep 'bashkit = ' native/ex_bashkit/Cargo.toml
```

### 1.2 Read the upstream changelog and API diff

bashkit keeps a CHANGELOG. If you have a local checkout at `../bashkit`:

```bash
cd ../bashkit && git fetch --tags
git log --oneline v<CURRENT>..v<NEW> -- crates/bashkit/
git diff v<CURRENT>..v<NEW> -- crates/bashkit/src/lib.rs   # public re-exports
```

`crates/bashkit/src/lib.rs` is the public surface. Watch for changes to the
types/functions **we actually use** (see the table in Phase 2).

---

## Phase 2: Classify changes

Sort what you find. Our binding currently touches a small surface; it grows as
phases land (see `PORTING.md`).

| We use | Where in our code | Since |
|--------|-------------------|-------|
| `Bash::new()`, `Bash::builder()`, `.build()`, `.exec()` | `lib.rs` | P1/P2 |
| `ExecResult { stdout, stderr, exit_code }` | `lib.rs` `encode_exec_result` → `ExBashkit.Result` | P1 |
| Builder `.env/.cwd/.username/.hostname` | `lib.rs` `session_new` | P2 |
| `Bash::fs()` getter; `FileSystem` trait (`read_file`/`write_file`/`mkdir`/`exists`) | `lib.rs` `session_read_file`/`session_write_file` | P3 |
| `.fs(...)` builder, `MountableFs` (the layer `bash.fs()` returns) | implicit via `build()` | P3 |
| `RealFs::new`, `RealFsMode`, builder `.mount_real_{readonly,readwrite}_at`, `.allowed_mount_paths` | `lib.rs` `session_new` mount loop | P3 |
| `ExecutionLimits` + setters, builder `.limits()` | `lib.rs` `decode_limits` | P4 |
| `NetworkAllowlist`, builder `.network(...)`, `http_client` feature | `lib.rs` `decode_network` / `session_new` | P5 |
| `Builtin` trait, `.builtin(...)`, execution extensions | `lib.rs` Elixir back-call bridge | P6 |
| `FileSystem` / `FileSystemExt` custom mount implementations | `lib.rs` `ElixirFs` | P6b |
| `SnapshotOptions`, snapshot/restore methods | `lib.rs` snapshot NIFs | P8 |
| `bashkit::is_sensitive_mount_path` (public since 0.18) | `lib.rs` `session_new` mount loop | 0.21 |
| `FsLimits::new().validate_path` | `lib.rs` `ElixirFs::call` path guard | 0.21 |
| Feature flags: `realfs`, `jq`, `tzdata`, and our default `http_client` mapping (`bashkit/http_client` + `bashkit/ring`) (enabled); `sqlite`/bashkit `python`/… (off) | `Cargo.toml` | — |

When a bump breaks the build, the failure almost always points at one of these
rows. `RealFsMode` (RO/RW only — no overlay) and the sensitive-path denylist
(includes `/private`) are the most likely to shift.

**Breaking** = a signature/type/field we use changed → must fix before bumping.
**Non-breaking** = new builtins, perf, internal fixes → just pick up.
**New capability** = a new builder option or feature we may want to expose.

Also check whether bashkit's **MSRV** rose (bump `rust-version` in Cargo.toml)
and whether any **feature** we enable was renamed or split.

Three security invariants live at the wrapper boundary and must be re-checked
against the new bashkit source on every bump:

- **Sensitive mount paths.** `session_new` refuses a sensitive host mount with
  a construction error, because bashkit only warns and skips it. Since 0.21 we
  call upstream's public `bashkit::is_sensitive_mount_path` instead of keeping
  a copy, so there is nothing to diff, but confirm the function is still
  exported and still the one `apply_real_mounts` consults.
- **`validate_entry_name`** protects recursive walkers from malformed
  external-FS directory entries even if upstream traversal internals change.
- **Path limits in `ElixirFs::call`.** bashkit's bulk `FileSystem::walk` hook
  reads a mounted backend directly, below the `MountableFs` layer that applies
  the depth/length caps. Without our guard a self-listing backend is walked
  ~10k levels deep and `du` overflows the native stack, killing the VM. Run
  `test/ex_bashkit/session_vfs_malformed_listing_test.exs` and, when upstream
  adds a recursive walker, try it against an infinitely deep `:virtual_fs`.

Behaviour changes do not show up as build failures. After the build is green,
diff a handful of script outputs between the old and new pin (virtual-mount
listings, `date` with a named `TZ`, restoring a snapshot written by the last
published release) before pinning.

---

## Phase 3: Update

### 3.1 Switch to a path dep for iteration

In `native/ex_bashkit/Cargo.toml`:

```toml
# bashkit = { version = "=0.21.0", default-features = false, features = ["realfs", "jq", "tzdata"] }
bashkit = { path = "../../../bashkit/crates/bashkit", default-features = false, features = ["realfs", "jq", "tzdata"] }
```

(Assumes a bashkit checkout at `../bashkit` relative to the project root, with
the target tag checked out: `git -C ../bashkit checkout v<NEW>`.)

> **Keep the feature set in sync.** We build `default-features = false` plus
> dependency features `realfs`, `jq`, and `tzdata`. Network is enabled through
> *our crate's* default `http_client = ["bashkit/http_client", "bashkit/ring"]`
> feature mapping. Carry both the dependency features and that mapping through
> the path-dep swap and re-pin. Because we opt out of defaults, check upstream's
> `default = [...]` list on every bump: anything newly moved behind a default-on
> feature (as `ring` and `tzdata` were in 0.17) silently disappears for us.

### 3.2 Build and fix

```bash
cd native/ex_bashkit && cargo check
```

Common fixes: renamed types (find/replace), changed `ExecResult` fields (update
the encode in `lib.rs`), new builder signatures (thread new options from
Elixir), new feature names (`Cargo.toml`).

### 3.3 Update the Elixir side if needed

- `lib/ex_bashkit/native.ex` — keep NIF stubs in sync with the Rust fns.
- `lib/ex_bashkit.ex`, `lib/ex_bashkit/*.ex` — new structs/options.

### 3.4 Run the suite

```bash
EXBASHKIT_BUILD=1 mix test
cd native/ex_bashkit && cargo fmt --check && cargo clippy -- -D warnings
cargo audit
```

### 3.5 Update docs

README capability tables, moduledocs, `@spec`s for any changed signature, and a
CHANGELOG `[Unreleased]` entry from the **user's** perspective.

---

## Phase 4: Pin and ship a release

### 4.1 Re-pin to the exact released version

```toml
bashkit = { version = "=0.<new>.0", default-features = false, features = ["realfs", "jq", "tzdata"] }
# path dep commented out
```

```bash
cd native/ex_bashkit && cargo update      # also refreshes transitive deps
cargo audit                               # must be clean on the final lockfile
cd ../.. && mix clean && EXBASHKIT_BUILD=1 mix test
```

### 4.2 Cut the ExBashkit release

`release.yml` automates the precompiled-NIF dance:

1. Decide the ExBashkit version (semver against *our* API, not bashkit's). Bump
   `@version` in `mix.exs`; finalize the CHANGELOG section.
2. Commit on `master` once the full gate is green.
3. Tag and push: `git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z`.
   This triggers `release.yml`, which builds NIFs for all 4 targets and creates
   the GitHub release with the `.tar.gz` artifacts.
4. The workflow then **pauses at the `hex` environment gate**. Confirm the
   release has 4 artifacts, then approve the "Publish to Hex" deployment in
   the Actions UI — the irreversible outward step, and deliberately a human's.
5. On approval the workflow regenerates
   `checksum-Elixir.ExBashkit.Native.exs` from the released artifacts (the
   canonical `mix rustler_precompiled.download --all` path, so packaged
   checksums always match what fetch-time expects), publishes the package to
   Hex, and pushes docs to HexDocs. No manual checksum commit, no re-tag.

The repo's checked-in checksum file is not updated per release; only the Hex
package carries the fresh one. Anyone consuming ExBashkit as a **git**
dependency must build locally with `EXBASHKIT_BUILD=1`.

### 4.3 Commit message shape

```
Update bashkit to 0.<new>.0

- <breaking changes fixed>
- <new capabilities exposed>
- <upstream improvements picked up>
```

---

## When to update

- **A new bashkit release** on crates.io — the natural cadence.
- **Immediately** if upstream fixes a sandbox-escape / security bug.
- **Before any ExBashkit release**, to ship on the latest stable bashkit.
- **When you need a new builtin/feature** for a capability you're exposing.
