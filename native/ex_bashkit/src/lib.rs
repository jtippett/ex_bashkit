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

use bashkit::FileSystem;
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
/// Scheduled on a dirty CPU scheduler because execution is in-memory compute
/// that can run longer than the ~1ms a regular NIF is allowed to hold the
/// scheduler. Switch to `DirtyIo` once the network/http feature can block.
#[rustler::nif(schedule = "DirtyCpu")]
fn exec(env: Env<'_>, script: String) -> NifResult<Term<'_>> {
    let result = runtime().block_on(async {
        let mut bash = bashkit::Bash::new();
        bash.exec(&script).await
    });

    Ok(encode_exec_result(env, result))
}

/// Build a persistent session from decoded builder options and return it as an
/// opaque resource handle. Construction is infallible (`BashBuilder::build`
/// returns a `Bash`, not a `Result`); option validation/normalization happens on
/// the Elixir side. Dirty-scheduled because wiring up the interpreter's ~150
/// builtins is more work than a regular NIF should do inline.
#[rustler::nif(schedule = "DirtyCpu")]
fn session_new(
    env_vars: Vec<(String, String)>,
    cwd: Option<String>,
    username: Option<String>,
    hostname: Option<String>,
) -> ResourceArc<SessionResource> {
    let mut builder = bashkit::Bash::builder();

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

    let bash = builder.build();
    // Grab the interpreter's *actual* post-build filesystem handle, so host
    // read/write route through the same (possibly layered) FS scripts use.
    let fs = bash.fs();

    ResourceArc::new(SessionResource {
        bash: Mutex::new(bash),
        fs: AssertUnwindSafe(fs),
    })
}

/// Execute `script` against an existing session, mutating it in place so that
/// any env/cwd/filesystem/function changes persist for the next call.
///
/// The session `Mutex` is held for the whole script, serializing concurrent
/// `session_exec` calls on the same session. Dirty CPU for the same reason as
/// `exec`.
#[rustler::nif(schedule = "DirtyCpu")]
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
