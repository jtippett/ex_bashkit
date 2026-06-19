//! ExBashkit NIF — Elixir wrapper around the `bashkit` virtual bash interpreter.
//!
//! Exposes a stateless `exec/1` (fresh sandbox per call) and a persistent,
//! stateful `Session` (`session_new`/`session_exec`) whose env, cwd, virtual
//! filesystem, shell functions and aliases carry across calls. The remaining
//! surface (filesystem mounts, resource limits, network allowlist, custom
//! builtins that call back into Elixir, snapshot/resume) is the porting work —
//! see PORTING.md for the staged plan and the lessons carried over from ExMonty.

use std::panic::AssertUnwindSafe;
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};

use bashkit::{ExecutionLimits, FileSystem, RealFs, RealFsMode};
// `NetworkAllowlist` and the `.network()` builder method are themselves gated on
// bashkit's `http_client` feature, so our use of them must be too. We enable the
// feature in Cargo.toml (it ships in the precompiled NIF), but cfg-gating keeps
// the crate buildable with `--no-default-features` minus http_client.
#[cfg(feature = "http_client")]
use bashkit::NetworkAllowlist;
use rustler::{Binary, Encoder, Env, NifResult, OwnedBinary, Resource, ResourceArc, Term};
use tokio::runtime::Runtime;

/// A single process-wide multi-thread tokio runtime.
///
/// `bashkit::Bash::exec` is `async`; the BEAM is not. Rather than spin up a
/// runtime per call (expensive) we lazily build one and `block_on` it from
/// inside dirty NIFs. Multi-thread + `enable_all` is the safe default and is
/// required once the `sqlite` feature is enabled. The runtime lives for the
/// lifetime of the loaded NIF library.
fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("failed to build the ExBashkit tokio runtime")
    })
}

/// A persistent, stateful bash interpreter held across NIF calls.
///
/// A `bashkit::Bash` accumulates state — environment variables, the current
/// working directory, the in-memory virtual filesystem, shell functions and
/// aliases — across `exec` calls. We wrap it in a `Mutex` so that a single
/// session is driven by at most one `exec` at a time (the lock is held for the
/// duration of the script, on the dirty scheduler thread). The `ResourceArc`
/// keeps it alive on the Elixir side as an opaque handle.
///
/// We also keep a clone of the interpreter's filesystem handle, obtained via
/// `bash.fs()` *after* `build()`. That is the exact FS the interpreter routes
/// through — `MountableFs` over the in-memory base, plus whatever overlay /
/// read-only / real-mount layers the builder applied — so host-side
/// `read_file`/`write_file` see precisely what scripts see, and vice versa, no
/// matter how the FS is layered (this matters once mounts/overlays land). The FS
/// has its own internal synchronization, so those calls don't take the `bash`
/// lock — the host can read/write files even while a script runs.
///
/// The `fs` is wrapped in `AssertUnwindSafe` because rustler runs each NIF
/// inside `catch_unwind`, which requires every resource argument to be
/// `RefUnwindSafe`; `dyn FileSystem` is not (interior mutability). This is the
/// same shielding `Mutex<Bash>` gets for free — and sound here, since every FS
/// operation is self-contained, so observing the FS after a panic is fine.
struct SessionResource {
    bash: Mutex<bashkit::Bash>,
    fs: AssertUnwindSafe<Arc<dyn FileSystem>>,
}

#[rustler::resource_impl]
impl Resource for SessionResource {}

/// Encode a bashkit run as `{:ok, {stdout, stderr, exit_code}}`, or an
/// interpreter/parse error as `{:error, message}`. Shared by the stateless and
/// session execution paths so both marshal results identically.
fn encode_exec_result<'a>(env: Env<'a>, result: bashkit::Result<bashkit::ExecResult>) -> Term<'a> {
    match result {
        Ok(r) => {
            let ok = rustler::types::atom::ok().encode(env);
            let payload = rustler::types::tuple::make_tuple(
                env,
                &[
                    r.stdout.encode(env),
                    r.stderr.encode(env),
                    r.exit_code.encode(env),
                ],
            );
            rustler::types::tuple::make_tuple(env, &[ok, payload])
        }
        Err(e) => {
            let error = rustler::types::atom::error().encode(env);
            let msg = e.to_string().encode(env);
            rustler::types::tuple::make_tuple(env, &[error, msg])
        }
    }
}

/// Run a bash script in a fresh, fully sandboxed interpreter and return
/// `{:ok, {stdout, stderr, exit_code}}` or `{:error, message}`.
///
/// This is intentionally stateless: each call builds a fresh `Bash`, so no
/// filesystem or environment carries across calls. Use a `Session` (below) when
/// you need state to persist.
///
/// Scheduled on a dirty **CPU** scheduler: this stateless path builds a default
/// `Bash` with no network allowlist, so curl/wget are refused before any socket
/// opens — execution is pure in-memory compute that can merely run longer than
/// the ~1ms a regular NIF may hold a scheduler. (The stateful `session_exec`,
/// which *can* be granted network access, uses `DirtyIo` for that reason.)
#[rustler::nif(schedule = "DirtyCpu")]
fn exec(env: Env<'_>, script: String) -> NifResult<Term<'_>> {
    let result = runtime().block_on(async {
        let mut bash = bashkit::Bash::new();
        bash.exec(&script).await
    });

    Ok(encode_exec_result(env, result))
}

/// Decode an Elixir `:limits` map into `ExecutionLimits`, applying only the keys
/// present (others keep bashkit's defaults). Returns `None` when no limits were
/// given, so the caller skips `.limits()` entirely. Values are pre-validated on
/// the Elixir side (known keys, non-negative integers), so missing/ill-typed
/// keys are simply ignored here.
fn decode_limits<'a>(env: Env<'a>, limits: Term<'a>) -> Option<ExecutionLimits> {
    if !limits.is_map() {
        return None;
    }

    let get = |key: &str| -> Option<usize> {
        let k = rustler::types::atom::Atom::from_str(env, key)
            .ok()?
            .encode(env);
        // `map_get` errors only when the key is absent -> keep bashkit's default.
        // A value too large for `usize` means "effectively unlimited", so saturate
        // to `usize::MAX` rather than silently dropping back to the (tighter)
        // default — that would be the opposite of the caller's intent.
        let term = limits.map_get(k).ok()?;
        Some(term.decode::<usize>().unwrap_or(usize::MAX))
    };

    let mut l = ExecutionLimits::default();
    let mut any = false;

    if let Some(n) = get("max_commands") {
        l = l.max_commands(n);
        any = true;
    }
    if let Some(n) = get("max_loop_iterations") {
        l = l.max_loop_iterations(n);
        any = true;
    }
    if let Some(n) = get("max_total_loop_iterations") {
        l = l.max_total_loop_iterations(n);
        any = true;
    }
    if let Some(n) = get("max_function_depth") {
        l = l.max_function_depth(n);
        any = true;
    }
    if let Some(n) = get("max_input_bytes") {
        l = l.max_input_bytes(n);
        any = true;
    }
    if let Some(ms) = get("timeout_ms") {
        l = l.timeout(std::time::Duration::from_millis(ms as u64));
        any = true;
    }

    if any {
        Some(l)
    } else {
        None
    }
}

/// Decode the Elixir `:allow_net`/`:block_private_ips` options (pre-normalized
/// into a map on the Elixir side) into a `NetworkAllowlist`. Returns `None` when
/// no network was configured, so the caller skips `.network()` entirely and the
/// session stays default-deny (curl/wget cannot reach anything).
///
/// Shape of the map (Elixir guarantees it; we read defensively):
///   - `%{}`                                         -> no network
///   - `%{allow_all: true, block_private_ips: bool}` -> allow every host
///   - `%{patterns: [..], block_private_ips: bool}`  -> allowlist those URLs
///
/// `block_private_ips` defaults to `true` (bashkit's SSRF default) if absent.
#[cfg(feature = "http_client")]
fn decode_network<'a>(env: Env<'a>, network: Term<'a>) -> Option<NetworkAllowlist> {
    if !network.is_map() {
        return None;
    }

    let get = |key: &str| -> Option<Term<'a>> {
        let k = rustler::types::atom::Atom::from_str(env, key)
            .ok()?
            .encode(env);
        network.map_get(k).ok()
    };

    let block_private_ips = get("block_private_ips")
        .and_then(|t| t.decode::<bool>().ok())
        .unwrap_or(true);

    if get("allow_all").and_then(|t| t.decode::<bool>().ok()) == Some(true) {
        return Some(NetworkAllowlist::allow_all().block_private_ips(block_private_ips));
    }

    let patterns: Vec<String> = get("patterns")
        .and_then(|t| t.decode::<Vec<String>>().ok())
        .unwrap_or_default();
    // An empty allowlist denies everything, which is identical to "no network":
    // leave `.network()` unset so the session reports a clean default-deny.
    if patterns.is_empty() {
        return None;
    }

    Some(
        NetworkAllowlist::new()
            .allow_many(patterns)
            .block_private_ips(block_private_ips),
    )
}

/// Encode a host-mount configuration error as `{:error, message}`.
fn mount_error<'a>(env: Env<'a>, vfs: &str, host: &str, reason: &str) -> Term<'a> {
    let error = rustler::types::atom::error().encode(env);
    let msg = format!("mount {vfs:?} -> {host:?}: {reason}").encode(env);
    rustler::types::tuple::make_tuple(env, &[error, msg])
}

/// Build a persistent session from decoded builder options. Returns
/// `{:ok, session}` or, if a host mount is misconfigured, `{:error, message}`.
///
/// Host mounts are validated eagerly with bashkit's own `RealFs::new` (which
/// canonicalizes the host path and checks it is an existing directory) so a bad
/// mount is a clean error rather than the silent skip the builder would do.
/// bashkit still performs every security check at run time (path canonicalization,
/// symlink-escape rejection, sensitive-path default-deny) — we only surface the
/// common misconfiguration up front. Dirty-scheduled because wiring up the
/// interpreter's ~150 builtins is more work than a regular NIF should do inline.
#[allow(clippy::too_many_arguments)]
#[rustler::nif(schedule = "DirtyCpu")]
fn session_new<'a>(
    env: Env<'a>,
    env_vars: Vec<(String, String)>,
    cwd: Option<String>,
    username: Option<String>,
    hostname: Option<String>,
    mounts: Vec<(String, String, String)>,
    allowed_mount_paths: Vec<String>,
    limits: Term<'a>,
    network: Term<'a>,
) -> Term<'a> {
    let mut builder = bashkit::Bash::builder();

    if let Some(limits) = decode_limits(env, limits) {
        builder = builder.limits(limits);
    }

    // Configure the network allowlist (curl/wget/http) when the script asked for
    // it. With `http_client` disabled there is no network surface, so ignore it.
    #[cfg(feature = "http_client")]
    if let Some(allowlist) = decode_network(env, network) {
        builder = builder.network(allowlist);
    }
    #[cfg(not(feature = "http_client"))]
    let _ = network;

    if let Some(username) = username {
        builder = builder.username(username);
    }
    if let Some(hostname) = hostname {
        builder = builder.hostname(hostname);
    }
    if let Some(cwd) = cwd {
        builder = builder.cwd(cwd);
    }
    for (key, value) in env_vars {
        builder = builder.env(key, value);
    }

    if !allowed_mount_paths.is_empty() {
        builder = builder.allowed_mount_paths(allowed_mount_paths);
    }

    for (vfs, host, mode) in &mounts {
        let real_mode = match mode.as_str() {
            "read_only" => RealFsMode::ReadOnly,
            "read_write" => RealFsMode::ReadWrite,
            other => return mount_error(env, vfs, host, &format!("unknown mount mode {other:?}")),
        };

        // Validate the host path with bashkit's own RealFs (canonicalize + must
        // be an existing directory). On success we discard it and let the builder
        // re-create the mount during `build()`.
        if let Err(e) = RealFs::new(host, real_mode) {
            return mount_error(env, vfs, host, &e.to_string());
        }

        builder = match real_mode {
            RealFsMode::ReadOnly => builder.mount_real_readonly_at(host, vfs),
            RealFsMode::ReadWrite => builder.mount_real_readwrite_at(host, vfs),
        };
    }

    let bash = builder.build();
    // Grab the interpreter's *actual* post-build filesystem handle, so host
    // read/write route through the same (possibly layered) FS scripts use.
    let fs = bash.fs();

    // bashkit *silently skips* mounts it refuses (a sensitive host path with no
    // covering allowlist entry, an invalid mount point, or a dir removed since
    // validation) — it only warns on stderr. Verify each mount point now exists,
    // so a dropped mount is a clean error instead of a session where the mount
    // silently isn't there. The freshly built base FS has no user vfs paths yet
    // (file seeding happens later, Elixir-side), so a missing mount point means
    // the mount was dropped. (Caveat: a skip whose vfs collides with a default
    // dir like `/tmp` can't be distinguished this way; Elixir requires an
    // absolute non-root vfs, which covers the common fresh-path case.)
    for (vfs, host, _mode) in &mounts {
        let present = runtime().block_on(async { fs.exists(Path::new(vfs)).await });
        if !matches!(present, Ok(true)) {
            return mount_error(
                env,
                vfs,
                host,
                "rejected by bashkit (sensitive host path without a covering \
                 allowed_mount_paths entry, or an invalid mount point)",
            );
        }
    }

    let session = ResourceArc::new(SessionResource {
        bash: Mutex::new(bash),
        fs: AssertUnwindSafe(fs),
    });

    let ok = rustler::types::atom::ok().encode(env);
    rustler::types::tuple::make_tuple(env, &[ok, session.encode(env)])
}

/// Execute `script` against an existing session, mutating it in place so that
/// any env/cwd/filesystem/function changes persist for the next call.
///
/// The session `Mutex` is held for the whole script, serializing concurrent
/// `session_exec` calls on the same session. Dirty **IO** for the same reason as
/// `exec`: a networked script can block on a socket, which must not run on a
/// dirty-CPU thread.
#[rustler::nif(schedule = "DirtyIo")]
fn session_exec<'a>(
    env: Env<'a>,
    session: ResourceArc<SessionResource>,
    script: String,
) -> Term<'a> {
    // Recover from a poisoned lock rather than bricking the session forever: if a
    // prior `exec` panicked inside bashkit, the guard was dropped mid-unwind and
    // poisoned this Mutex. The interpreter state is still usable, so take it back
    // (matches ExMonty's `drive_with_mounts` recovery) instead of `unwrap`-panicking.
    let mut bash = session
        .bash
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let result = runtime().block_on(async { bash.exec(&script).await });
    encode_exec_result(env, result)
}

/// Read a file from the session's virtual filesystem on the host's behalf,
/// returning `{:ok, binary}` or `{:error, message}`. Operates on the shared FS
/// `Arc` directly (no `bash` lock), so it works even mid-script.
#[rustler::nif(schedule = "DirtyCpu")]
fn session_read_file<'a>(
    env: Env<'a>,
    session: ResourceArc<SessionResource>,
    path: String,
) -> Term<'a> {
    let fs = Arc::clone(&session.fs.0);
    let result = runtime().block_on(async move { fs.read_file(Path::new(&path)).await });

    match result {
        Ok(bytes) => match OwnedBinary::new(bytes.len()) {
            Some(mut bin) => {
                bin.as_mut_slice().copy_from_slice(&bytes);
                let ok = rustler::types::atom::ok().encode(env);
                let payload = bin.release(env).encode(env);
                rustler::types::tuple::make_tuple(env, &[ok, payload])
            }
            // Honor the {:error, _} contract rather than panicking the caller
            // if the BEAM can't allocate a binary for a very large file.
            None => {
                let error = rustler::types::atom::error().encode(env);
                let msg = "could not allocate a binary for the file contents".encode(env);
                rustler::types::tuple::make_tuple(env, &[error, msg])
            }
        },
        Err(e) => {
            let error = rustler::types::atom::error().encode(env);
            let msg = e.to_string().encode(env);
            rustler::types::tuple::make_tuple(env, &[error, msg])
        }
    }
}

/// Write a file into the session's virtual filesystem on the host's behalf
/// (creating parent directories), returning `:ok` or `{:error, message}`. Also
/// the seeding primitive behind `Session.new(files: ...)`.
#[rustler::nif(schedule = "DirtyCpu")]
fn session_write_file<'a>(
    env: Env<'a>,
    session: ResourceArc<SessionResource>,
    path: String,
    content: Binary<'a>,
) -> Term<'a> {
    let fs = Arc::clone(&session.fs.0);
    let bytes = content.as_slice().to_vec();
    let result = runtime().block_on(async move {
        // `write_file` requires the parent to exist; create it (mkdir -p) first
        // so `write_file`/`Session.new(files: ...)` behave like a shell redirect
        // into a fresh path.
        let path = Path::new(&path);
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                fs.mkdir(parent, true).await?;
            }
        }
        fs.write_file(path, &bytes).await
    });

    match result {
        Ok(()) => rustler::types::atom::ok().encode(env),
        Err(e) => {
            let error = rustler::types::atom::error().encode(env);
            let msg = e.to_string().encode(env);
            rustler::types::tuple::make_tuple(env, &[error, msg])
        }
    }
}

rustler::init!("Elixir.ExBashkit.Native");
