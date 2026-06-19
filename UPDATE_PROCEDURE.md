# ExBashkit Update Procedure

Run this periodically to pull upstream bashkit changes into ExBashkit.

ExBashkit pins an **exact** bashkit version in `native/ex_bashkit/Cargo.toml`
(`bashkit = "=0.11.0"`). Unlike monty (git-only), bashkit is published to
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
git log --oneline v0.11.0..v<NEW> -- crates/bashkit/
git diff v0.11.0..v<NEW> -- crates/bashkit/src/lib.rs   # public re-exports
```

`crates/bashkit/src/lib.rs` is the public surface. Watch for changes to the
types/functions **we actually use** (see the table in Phase 2).

---

## Phase 2: Classify changes

Sort what you find. Our binding currently touches a small surface; it grows as
phases land (see `PORTING.md`).

| We use | Where in our code |
|--------|-------------------|
| `Bash::new()`, `Bash::builder()`, `.exec()` | `native/ex_bashkit/src/lib.rs` |
| `ExecResult { stdout, stderr, exit_code, ... }` | `lib.rs` encode → `ExBashkit.Result` |
| `Bash::builder()` options (env, cwd, fs, limits, network) | added per phase |
| `ExecutionLimits`, fs types (`InMemoryFs`, `MountableFs`, `OverlayFs`) | added per phase |
| `Snapshot`, `SnapshotOptions` | added in phase 8 |
| `Builtin` trait, `register_builtin` | added in phase 6 |
| Feature flags (`bash_tool`, `sqlite`, `python`, …) | `Cargo.toml` `[dependencies]` |

**Breaking** = a signature/type/field we use changed → must fix before bumping.
**Non-breaking** = new builtins, perf, internal fixes → just pick up.
**New capability** = a new builder option or feature we may want to expose.

Also check whether bashkit's **MSRV** rose (bump `rust-version` in Cargo.toml)
and whether any **feature** we enable was renamed or split.

---

## Phase 3: Update

### 3.1 Switch to a path dep for iteration

In `native/ex_bashkit/Cargo.toml`:

```toml
# bashkit = { version = "=0.11.0", default-features = false }
bashkit = { path = "../../../bashkit/crates/bashkit", default-features = false }
```

(Assumes a bashkit checkout at `../bashkit` relative to the project root.)

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
```

### 3.5 Update docs

README capability tables, moduledocs, `@spec`s for any changed signature, and a
CHANGELOG `[Unreleased]` entry from the **user's** perspective.

---

## Phase 4: Pin and ship a release

### 4.1 Re-pin to the exact released version

```toml
bashkit = { version = "=0.<new>.0", default-features = false }
# path dep commented out
```

```bash
cd native/ex_bashkit && cargo update -p bashkit
cd ../.. && mix clean && EXBASHKIT_BUILD=1 mix test
```

### 4.2 Cut the ExBashkit release

This is the precompiled-NIF dance — **order matters**:

1. Decide the ExBashkit version (semver against *our* API, not bashkit's). Bump
   `@version` in `mix.exs`; finalize the CHANGELOG section.
2. Commit on `master`; open a PR; merge when CI is green.
3. Tag and push: `git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z`.
   This triggers `release.yml`, which builds NIFs for all 4 targets and creates
   the GitHub release with the `.tar.gz` artifacts.
4. **Wait for that workflow to finish.** Confirm the release has 4 artifacts.
5. Regenerate checksums (note `EXBASHKIT_BUILD=1` to dodge the compile
   chicken-and-egg):
   ```bash
   EXBASHKIT_BUILD=1 mix rustler_precompiled.download ExBashkit.Native --all --print
   ```
6. Commit the updated `checksum-Elixir.ExBashkit.Native.exs` and push.
7. `mix hex.publish` — the irreversible outward step (needs your Hex auth).

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
