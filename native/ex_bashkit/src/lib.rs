//! ExBashkit NIF — Elixir wrapper around the `bashkit` virtual bash interpreter.
//!
//! Exposes a stateless `exec/1` (fresh sandbox per call) and a persistent,
//! stateful `Session` (`session_new`/`session_exec`) whose env, cwd, virtual
//! filesystem, shell functions and aliases carry across calls. The remaining
//! surface (filesystem mounts, resource limits, network allowlist, custom
//! builtins that call back into Elixir, snapshot/resume) is the porting work —
//! see PORTING.md for the staged plan and the lessons carried over from ExMonty.

use std::sync::{Mutex, OnceLock};

use rustler::{Encoder, Env, NifResult, Resource, ResourceArc, Term};
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
struct SessionResource {
    bash: Mutex<bashkit::Bash>,
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

    ResourceArc::new(SessionResource {
        bash: Mutex::new(builder.build()),
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

rustler::init!("Elixir.ExBashkit.Native");
