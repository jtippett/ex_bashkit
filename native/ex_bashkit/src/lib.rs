//! ExBashkit NIF — Elixir wrapper around the `bashkit` virtual bash interpreter.
//!
//! Status: SKELETON. This compiles and proves the full toolchain end-to-end
//! (rustler link + tokio bridge + bashkit `exec` + precompiled-NIF pipeline),
//! exposing a single stateless `exec/1`. The real surface (persistent sessions,
//! virtual-filesystem mounts, resource limits, network allowlist, custom
//! builtins that call back into Elixir, snapshot/resume) is the porting work —
//! see PORTING.md for the staged plan and the lessons carried over from ExMonty.

use std::sync::OnceLock;

use rustler::{Encoder, Env, NifResult, Term};
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

/// Run a bash script in a fresh, fully sandboxed interpreter and return
/// `{:ok, {stdout, stderr, exit_code}}` or `{:error, message}`.
///
/// This is intentionally stateless: each call builds a fresh `Bash`, so no
/// filesystem or environment carries across calls. A persistent-session
/// resource (`ResourceArc<Mutex<Bash>>`) is the first real porting task — see
/// PORTING.md "Phase 2: sessions & state".
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
            Ok(rustler::types::tuple::make_tuple(env, &[ok, payload]))
        }
        Err(e) => {
            let error = rustler::types::atom::error().encode(env);
            let msg = e.to_string().encode(env);
            Ok(rustler::types::tuple::make_tuple(env, &[error, msg]))
        }
    }
}

rustler::init!("Elixir.ExBashkit.Native");
