//! ExBashkit NIF — Elixir wrapper around the `bashkit` virtual bash interpreter.
//!
//! Exposes a stateless `exec/1` (fresh sandbox per call) and a persistent,
//! stateful `Session` (`session_new`/`session_exec`) whose env, cwd, virtual
//! filesystem, shell functions and aliases carry across calls. The remaining
//! surface (filesystem mounts, resource limits, network allowlist, custom
//! builtins that call back into Elixir, snapshot/resume) is the porting work —
//! see PORTING.md for the staged plan and the lessons carried over from ExMonty.

use std::collections::HashMap;
use std::panic::AssertUnwindSafe;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use bashkit::{
    async_trait, Builtin, BuiltinContext, ExecResult, ExecutionExtensions, ExecutionLimits,
    FileSystem, FileSystemExt, RealFs, RealFsMode, SnapshotOptions,
};
// `NetworkAllowlist` and the `.network()` builder method are themselves gated on
// bashkit's `http_client` feature, so our use of them must be too. We enable the
// feature in Cargo.toml (it ships in the precompiled NIF), but cfg-gating keeps
// the crate buildable with `--no-default-features` minus http_client.
#[cfg(feature = "http_client")]
use bashkit::NetworkAllowlist;
use rustler::{
    Binary, Encoder, Env, LocalPid, NifResult, OwnedBinary, OwnedEnv, Resource, ResourceArc, Term,
};
use tokio::runtime::Runtime;
use tokio::sync::oneshot;

mod atoms {
    rustler::atoms! { bashkit_call, bashkit_fs, ok_bytes, ok_list, ok_stat, dir, file, symlink }
}

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
    /// This session's current back-call target (handler pid + timeout), shared
    /// with every mounted `ElixirFs`. `FileSystem` methods have no execution
    /// context, so `session_exec` publishes it here for the duration of a run.
    fs_target: Arc<Mutex<Option<CallTarget>>>,
}

#[rustler::resource_impl]
impl Resource for SessionResource {}

// --- Elixir-defined custom builtins (the back-call bridge) ------------------
//
// A custom builtin runs *inside* bashkit's async execution. To service it from
// Elixir we do a round-trip: the builtin parks a reply channel in a global
// table keyed by a request id, sends `{:bashkit_call, req_id, name, args,
// stdin, env}` to a per-exec handler pid, and `await`s the channel. An Elixir
// handler process computes the result and calls the `builtin_reply` NIF, which
// pushes it back into the channel. Awaiting (vs blocking) frees the tokio worker
// while the host thinks; only the outer dirty-scheduler thread stays pinned for
// the script, which is inherent to the synchronous `exec/2` API.

/// The result an Elixir handler sends back for one builtin invocation.
struct BuiltinReply {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    exit_code: i32,
}

/// Pending builtin invocations awaiting an Elixir reply, keyed by request id.
fn pending_calls() -> &'static Mutex<HashMap<u64, oneshot::Sender<BuiltinReply>>> {
    static PENDING: OnceLock<Mutex<HashMap<u64, oneshot::Sender<BuiltinReply>>>> = OnceLock::new();
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Monotonic request-id source for back-calls (process-wide, never reused).
fn next_request_id() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

/// Removes a request's slot from `pending_calls` on *every* exit path of the
/// builtin future — normal return, error, timeout, and crucially **cancellation**
/// (bashkit's execution timeout drops the whole `execute` future mid-`await`,
/// which would otherwise leak the parked sender forever). Idempotent with the
/// removal `builtin_reply` does, so whichever runs first wins.
struct PendingCleanup(u64);

impl Drop for PendingCleanup {
    fn drop(&mut self) {
        pending_calls()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(&self.0);
    }
}

/// Per-execution context for back-calls, threaded into `exec_with_extensions`
/// and read by a builtin via `ctx.execution_extension::<CallTarget>()`. The pid
/// is *this exec's* handler process; the timeout bounds a single back-call.
#[derive(Clone, Copy)]
struct CallTarget {
    handler: LocalPid,
    timeout: Duration,
}

/// Clears a session's `fs_target` cell on scope exit (normal return *or* a panic
/// unwinding out of `session_exec`), so a panicked exec never leaves a stale
/// handler pid behind for the next virtual-FS back-call. Mirrors `PendingCleanup`.
struct FsTargetGuard(Arc<Mutex<Option<CallTarget>>>);

impl Drop for FsTargetGuard {
    fn drop(&mut self) {
        *self.0.lock().unwrap_or_else(|p| p.into_inner()) = None;
    }
}

/// Build an `ExecResult` from raw stdout/stderr bytes and an exit code. Sets
/// `stdout_bytes` so binary output round-trips exactly, and a lossy `stdout`
/// string for the text path (pipes, captures).
fn builtin_exec_result(stdout: Vec<u8>, stderr: Vec<u8>, exit_code: i32) -> ExecResult {
    ExecResult {
        stdout: String::from_utf8_lossy(&stdout).into_owned(),
        stdout_bytes: Some(stdout),
        stderr: String::from_utf8_lossy(&stderr).into_owned(),
        exit_code,
        ..Default::default()
    }
}

/// A failed back-call surfaced as the builtin's own non-zero exit + stderr, so a
/// misbehaving host never wedges the session — just fails that command.
fn builtin_error_result(message: String, exit_code: i32) -> ExecResult {
    builtin_exec_result(Vec::new(), message.into_bytes(), exit_code)
}

/// A virtual executable backed by an Elixir function. Registered by *name* at
/// build time; the closure itself lives entirely on the Elixir side.
struct ElixirBuiltin {
    name: String,
}

#[async_trait]
impl Builtin for ElixirBuiltin {
    async fn execute(&self, ctx: BuiltinContext<'_>) -> bashkit::Result<ExecResult> {
        let Some(target) = ctx.execution_extension::<CallTarget>().copied() else {
            // No handler wired for this exec — shouldn't happen (we always set
            // one), but fail the command rather than panic.
            return Ok(builtin_error_result(
                format!(
                    "{}: no Elixir handler is available for this execution",
                    self.name
                ),
                1,
            ));
        };

        // Snapshot the call context into owned data we can ship to Elixir.
        let args: Vec<String> = ctx.args.to_vec();
        let stdin: Vec<u8> = ctx.stdin.map(|s| s.as_bytes().to_vec()).unwrap_or_default();
        let env: Vec<(String, String)> = ctx
            .env
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        // The interpreter's current working directory — not an exported env var,
        // so a builtin can't get it from `env`. Threaded through so builtins (the
        // `python` builtin in particular) can resolve relative paths.
        let cwd: String = ctx.cwd.to_string_lossy().into_owned();

        let req_id = next_request_id();
        let (tx, rx) = oneshot::channel::<BuiltinReply>();
        pending_calls()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(req_id, tx);
        // From here on, every exit path (return, timeout, or this future being
        // dropped on a script-timeout cancellation) must clear the slot.
        let _cleanup = PendingCleanup(req_id);

        // Send `{:bashkit_call, req_id, name, args, stdin, env, cwd}` to the handler.
        //
        // `OwnedEnv::send_and_clear` *panics* if called from a BEAM-managed
        // thread, and this future is polled on the dirty-scheduler thread (via
        // `block_on`). So hand the send to a tokio blocking thread (not
        // VM-managed) and await it. All captured data is owned and `Send`.
        let handler = target.handler;
        let name = self.name.clone();
        let send_outcome = tokio::task::spawn_blocking(move || {
            let mut owned = OwnedEnv::new();
            owned.send_and_clear(&handler, |env_| {
                let stdin_term = match OwnedBinary::new(stdin.len()) {
                    Some(mut bin) => {
                        bin.as_mut_slice().copy_from_slice(&stdin);
                        bin.release(env_).encode(env_)
                    }
                    None => "".encode(env_),
                };
                rustler::types::tuple::make_tuple(
                    env_,
                    &[
                        atoms::bashkit_call().encode(env_),
                        req_id.encode(env_),
                        name.encode(env_),
                        args.encode(env_),
                        stdin_term,
                        env.encode(env_),
                        cwd.encode(env_),
                    ],
                )
            })
        })
        .await;

        if !matches!(send_outcome, Ok(Ok(()))) {
            return Ok(builtin_error_result(
                format!("{}: Elixir handler is unavailable", self.name),
                1,
            ));
        }

        // Await the reply, bounded by the back-call timeout. `_cleanup` clears the
        // table slot on every branch below (and on cancellation).
        match tokio::time::timeout(target.timeout, rx).await {
            Ok(Ok(reply)) => Ok(builtin_exec_result(
                reply.stdout,
                reply.stderr,
                reply.exit_code,
            )),
            // Defensive: `rx` only errors if the sender were dropped without a
            // reply. The current design never does that (the slot holds the
            // sender until `builtin_reply` consumes it), so in practice a dead
            // handler surfaces as the timeout below — but handle it cleanly.
            Ok(Err(_)) => Ok(builtin_error_result(
                format!("{}: Elixir handler stopped before replying", self.name),
                1,
            )),
            Err(_elapsed) => Ok(builtin_error_result(
                format!(
                    "{}: builtin timed out after {}ms",
                    self.name,
                    target.timeout.as_millis()
                ),
                124,
            )),
        }
    }
}

/// Deliver an Elixir handler's result for one back-call into the waiting
/// builtin. A fast, regular NIF: a map lookup plus a non-blocking channel send.
/// A stale `req_id` (already timed out) is silently dropped.
#[rustler::nif]
fn builtin_reply(req_id: u64, stdout: Binary, stderr: Binary, exit_code: i32) -> rustler::Atom {
    if let Some(tx) = pending_calls()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .remove(&req_id)
    {
        let _ = tx.send(BuiltinReply {
            stdout: stdout.as_slice().to_vec(),
            stderr: stderr.as_slice().to_vec(),
            exit_code,
        });
    }
    rustler::types::atom::ok()
}

// --- Elixir-backed virtual filesystem (reuses the back-call bridge) ---------
//
// An `ElixirFs` is a `bashkit::FileSystem` mounted at a vfs path; its methods
// back-call Elixir the same way builtins do. The one structural difference:
// `FileSystem` methods receive only a `&Path` (no `Context`), so the per-exec
// handler pid can't ride an execution extension — it travels via a shared
// `Arc<Mutex<Option<CallTarget>>>` cell set by `session_exec` (safe because a
// session's execs are serialized by the `bash` lock). Replies are heterogeneous
// (bytes / unit / dir list / metadata), so a separate `fs_reply` NIF and table.

/// A normalized reply for one virtual-filesystem operation.
enum FsReply {
    Unit,
    Bytes(Vec<u8>),
    List(Vec<(String, bool)>),
    Stat { is_dir: bool, size: u64 },
    Error(String),
}

/// Pending FS back-calls awaiting an Elixir reply, keyed by request id.
fn pending_fs_calls() -> &'static Mutex<HashMap<u64, oneshot::Sender<FsReply>>> {
    static PENDING: OnceLock<Mutex<HashMap<u64, oneshot::Sender<FsReply>>>> = OnceLock::new();
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

/// RAII cleanup for the FS pending table (see `PendingCleanup`).
struct PendingFsCleanup(u64);

impl Drop for PendingFsCleanup {
    fn drop(&mut self) {
        pending_fs_calls()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(&self.0);
    }
}

/// Build a bashkit FS error from an errno-style reason (or a free-form string).
fn map_fs_error(reason: &str) -> bashkit::Error {
    use std::io::ErrorKind;
    let (kind, msg): (ErrorKind, String) = match reason {
        "enoent" => (ErrorKind::NotFound, "No such file or directory".into()),
        "eacces" | "eperm" => (ErrorKind::PermissionDenied, "Permission denied".into()),
        "eexist" => (ErrorKind::AlreadyExists, "File exists".into()),
        "eisdir" => (ErrorKind::Other, "Is a directory".into()),
        "enotdir" => (ErrorKind::Other, "Not a directory".into()),
        "enotsup" | "enosys" => (ErrorKind::Unsupported, "Operation not supported".into()),
        other => (ErrorKind::Other, other.to_string()),
    };
    std::io::Error::new(kind, msg).into()
}

/// A bashkit error for an internal bridge failure (handler gone, timeout, …).
fn fs_bridge_error(msg: &str) -> bashkit::Error {
    std::io::Error::other(msg.to_string()).into()
}

/// A `FileSystem` mounted at a vfs path whose operations are serviced by Elixir.
struct ElixirFs {
    /// The vfs mount point (e.g. `/api`); identifies the handler's backend.
    mount_path: String,
    /// This session's current back-call target, set per-exec by `session_exec`.
    target: Arc<Mutex<Option<CallTarget>>>,
}

impl ElixirFs {
    /// Perform one back-call: send `{:bashkit_fs, req_id, mount, op, path, data,
    /// recursive}` to the current handler and await the normalized reply.
    async fn call(
        &self,
        op: &'static str,
        path: &Path,
        data: Vec<u8>,
        recursive: bool,
    ) -> bashkit::Result<FsReply> {
        let target = (*self.target.lock().unwrap_or_else(|p| p.into_inner()))
            .ok_or_else(|| fs_bridge_error("no active execution for this virtual filesystem"))?;

        let req_id = next_request_id();
        let (tx, rx) = oneshot::channel::<FsReply>();
        pending_fs_calls()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(req_id, tx);
        let _cleanup = PendingFsCleanup(req_id);

        // `OwnedEnv::send_and_clear` panics on a BEAM-managed thread; send from a
        // tokio blocking thread (same reason as builtins).
        let handler = target.handler;
        let mount = self.mount_path.clone();
        let path = path.to_string_lossy().into_owned();
        let send_outcome = tokio::task::spawn_blocking(move || {
            let mut owned = OwnedEnv::new();
            owned.send_and_clear(&handler, |env_| {
                let op_atom = rustler::types::atom::Atom::from_str(env_, op)
                    .expect("op atom")
                    .encode(env_);
                let data_term = match OwnedBinary::new(data.len()) {
                    Some(mut bin) => {
                        bin.as_mut_slice().copy_from_slice(&data);
                        bin.release(env_).encode(env_)
                    }
                    None => "".encode(env_),
                };
                rustler::types::tuple::make_tuple(
                    env_,
                    &[
                        atoms::bashkit_fs().encode(env_),
                        req_id.encode(env_),
                        mount.encode(env_),
                        op_atom,
                        path.encode(env_),
                        data_term,
                        recursive.encode(env_),
                    ],
                )
            })
        })
        .await;

        if !matches!(send_outcome, Ok(Ok(()))) {
            return Err(fs_bridge_error("virtual filesystem handler is unavailable"));
        }

        match tokio::time::timeout(target.timeout, rx).await {
            Ok(Ok(reply)) => Ok(reply),
            Ok(Err(_)) => Err(fs_bridge_error(
                "virtual filesystem handler stopped before replying",
            )),
            Err(_elapsed) => Err(fs_bridge_error("virtual filesystem operation timed out")),
        }
    }

    /// Back-call expecting a unit (`:ok`) reply, mapping errors.
    async fn call_unit(
        &self,
        op: &'static str,
        path: &Path,
        data: Vec<u8>,
        recursive: bool,
    ) -> bashkit::Result<()> {
        match self.call(op, path, data, recursive).await? {
            FsReply::Unit => Ok(()),
            FsReply::Error(reason) => Err(map_fs_error(&reason)),
            _ => Err(fs_bridge_error("virtual filesystem: unexpected reply")),
        }
    }
}

fn is_mount_root(path: &Path) -> bool {
    let p = path.as_os_str();
    p.is_empty() || p == "/"
}

fn dir_metadata() -> bashkit::Metadata {
    bashkit::Metadata {
        file_type: bashkit::FileType::Directory,
        mode: 0o755,
        ..Default::default()
    }
}

// `FileSystem` requires `FileSystemExt`; all its methods (usage/limits/mkfifo/
// snapshot/…) have sensible defaults, so an empty impl is enough.
impl FileSystemExt for ElixirFs {}

#[async_trait]
impl FileSystem for ElixirFs {
    async fn read_file(&self, path: &Path) -> bashkit::Result<Vec<u8>> {
        match self.call("read", path, Vec::new(), false).await? {
            FsReply::Bytes(bytes) => Ok(bytes),
            FsReply::Error(reason) => Err(map_fs_error(&reason)),
            _ => Err(fs_bridge_error(
                "virtual filesystem: unexpected reply for read",
            )),
        }
    }

    async fn write_file(&self, path: &Path, content: &[u8]) -> bashkit::Result<()> {
        self.call_unit("write", path, content.to_vec(), false).await
    }

    async fn append_file(&self, path: &Path, content: &[u8]) -> bashkit::Result<()> {
        self.call_unit("append", path, content.to_vec(), false)
            .await
    }

    async fn mkdir(&self, path: &Path, recursive: bool) -> bashkit::Result<()> {
        self.call_unit("mkdir", path, Vec::new(), recursive).await
    }

    async fn remove(&self, path: &Path, recursive: bool) -> bashkit::Result<()> {
        self.call_unit("remove", path, Vec::new(), recursive).await
    }

    async fn stat(&self, path: &Path) -> bashkit::Result<bashkit::Metadata> {
        if is_mount_root(path) {
            return Ok(dir_metadata());
        }
        match self.call("stat", path, Vec::new(), false).await? {
            FsReply::Stat { is_dir, size } => Ok(bashkit::Metadata {
                file_type: if is_dir {
                    bashkit::FileType::Directory
                } else {
                    bashkit::FileType::File
                },
                size,
                mode: if is_dir { 0o755 } else { 0o644 },
                ..Default::default()
            }),
            FsReply::Error(reason) => Err(map_fs_error(&reason)),
            _ => Err(fs_bridge_error(
                "virtual filesystem: unexpected reply for stat",
            )),
        }
    }

    async fn read_dir(&self, path: &Path) -> bashkit::Result<Vec<bashkit::DirEntry>> {
        match self.call("list", path, Vec::new(), false).await? {
            FsReply::List(entries) => Ok(entries
                .into_iter()
                .map(|(name, is_dir)| bashkit::DirEntry {
                    name,
                    metadata: bashkit::Metadata {
                        file_type: if is_dir {
                            bashkit::FileType::Directory
                        } else {
                            bashkit::FileType::File
                        },
                        ..Default::default()
                    },
                })
                .collect()),
            FsReply::Error(reason) => Err(map_fs_error(&reason)),
            _ => Err(fs_bridge_error(
                "virtual filesystem: unexpected reply for list",
            )),
        }
    }

    async fn exists(&self, path: &Path) -> bashkit::Result<bool> {
        if is_mount_root(path) {
            return Ok(true);
        }
        // Derive existence from stat; ENOENT means "no", other errors propagate.
        match self.call("stat", path, Vec::new(), false).await? {
            FsReply::Stat { .. } => Ok(true),
            FsReply::Error(reason) if reason == "enoent" => Ok(false),
            FsReply::Error(reason) => Err(map_fs_error(&reason)),
            _ => Err(fs_bridge_error(
                "virtual filesystem: unexpected reply for exists",
            )),
        }
    }

    async fn rename(&self, _from: &Path, _to: &Path) -> bashkit::Result<()> {
        Err(unsupported_vfs_op())
    }

    async fn copy(&self, _from: &Path, _to: &Path) -> bashkit::Result<()> {
        Err(unsupported_vfs_op())
    }

    async fn symlink(&self, _target: &Path, _link: &Path) -> bashkit::Result<()> {
        Err(unsupported_vfs_op())
    }

    async fn read_link(&self, _path: &Path) -> bashkit::Result<std::path::PathBuf> {
        Err(unsupported_vfs_op())
    }

    async fn chmod(&self, _path: &Path, _mode: u32) -> bashkit::Result<()> {
        // chmod is meaningless on virtual files; succeed silently so scripts that
        // chmod (e.g. after writing) don't spuriously fail.
        Ok(())
    }
}

fn unsupported_vfs_op() -> bashkit::Error {
    std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "operation not supported on a virtual filesystem",
    )
    .into()
}

/// Decode an Elixir-normalized FS reply term into an `FsReply`. The handler
/// guarantees one of: `:ok` | `{:ok_bytes, bin}` | `{:ok_list, [{bin, bool}]}` |
/// `{:ok_stat, is_dir, size}` | `{:error, reason_bin}`. Anything else is a bug
/// surfaced as an I/O error rather than a panic.
fn decode_fs_reply(reply: Term<'_>) -> FsReply {
    if let Ok(atom) = reply.decode::<rustler::Atom>() {
        if atom == rustler::types::atom::ok() {
            return FsReply::Unit;
        }
        return FsReply::Error("eio".into());
    }

    let Ok(tuple) = rustler::types::tuple::get_tuple(reply) else {
        return FsReply::Error("eio".into());
    };
    let Some(tag) = tuple.first().and_then(|t| t.decode::<rustler::Atom>().ok()) else {
        return FsReply::Error("eio".into());
    };

    if tag == atoms::ok_bytes() {
        match tuple.get(1).and_then(|t| t.decode::<Binary>().ok()) {
            Some(bin) => FsReply::Bytes(bin.as_slice().to_vec()),
            None => FsReply::Error("eio".into()),
        }
    } else if tag == atoms::ok_list() {
        match tuple
            .get(1)
            .and_then(|t| t.decode::<Vec<(String, bool)>>().ok())
        {
            Some(entries) => FsReply::List(entries),
            None => FsReply::Error("eio".into()),
        }
    } else if tag == atoms::ok_stat() {
        match (
            tuple.get(1).and_then(|t| t.decode::<bool>().ok()),
            tuple.get(2).and_then(|t| t.decode::<u64>().ok()),
        ) {
            (Some(is_dir), Some(size)) => FsReply::Stat { is_dir, size },
            _ => FsReply::Error("eio".into()),
        }
    } else if tag == rustler::types::atom::error() {
        match tuple.get(1).and_then(|t| t.decode::<String>().ok()) {
            Some(reason) => FsReply::Error(reason),
            None => FsReply::Error("eio".into()),
        }
    } else {
        FsReply::Error("eio".into())
    }
}

/// Deliver an Elixir handler's reply for one FS back-call (see `builtin_reply`).
#[rustler::nif]
fn fs_reply(req_id: u64, reply: Term<'_>) -> rustler::Atom {
    let decoded = decode_fs_reply(reply);
    if let Some(tx) = pending_fs_calls()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .remove(&req_id)
    {
        let _ = tx.send(decoded);
    }
    rustler::types::atom::ok()
}

/// Encode a bashkit run as `{:ok, {stdout, stderr, exit_code}}`, or an
/// interpreter/parse error as `{:error, message}`. Shared by the stateless and
/// session execution paths so both marshal results identically.
fn encode_exec_result<'a>(env: Env<'a>, result: bashkit::Result<bashkit::ExecResult>) -> Term<'a> {
    match result {
        Ok(r) => {
            let ok = rustler::types::atom::ok().encode(env);
            // `r.stdout` is a (lossy) String. bashkit only carries exact
            // `stdout_bytes` on a *builtin's own* ExecResult, not on the script's
            // top-level result — its interpreter re-buffers output through a
            // String — so reading `stdout_bytes` here is always `None` and binary
            // builtin output is unavoidably lossy at the result boundary. That's a
            // bashkit limitation, not ours; we don't paper over it.
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
    builtin_names: Vec<String>,
    virtual_fs_paths: Vec<String>,
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

    // Register an Elixir-backed virtual executable for each name. The closures
    // live on the Elixir side; each `ElixirBuiltin` knows only its own name and
    // calls back per invocation (see the bridge above).
    for name in builtin_names {
        let builtin = ElixirBuiltin { name: name.clone() };
        builder = builder.builtin(name, Box::new(builtin));
    }

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

    // Mount each Elixir-backed virtual filesystem at its vfs path. They share the
    // per-exec `fs_target` cell (the FS trait has no execution context to read a
    // handler pid from); `session_exec` publishes the current target into it.
    let fs_target: Arc<Mutex<Option<CallTarget>>> = Arc::new(Mutex::new(None));
    for path in &virtual_fs_paths {
        let elixir_fs = ElixirFs {
            mount_path: path.clone(),
            target: Arc::clone(&fs_target),
        };
        if let Err(e) = bash.mount(path, Arc::new(elixir_fs)) {
            let error = rustler::types::atom::error().encode(env);
            let msg = format!("virtual_fs mount {path:?}: {e}").encode(env);
            return rustler::types::tuple::make_tuple(env, &[error, msg]);
        }
    }

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
        fs_target,
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
    handler: LocalPid,
    builtin_timeout_ms: u64,
) -> Term<'a> {
    // Recover from a poisoned lock rather than bricking the session forever: if a
    // prior `exec` panicked inside bashkit, the guard was dropped mid-unwind and
    // poisoned this Mutex. The interpreter state is still usable, so take it back
    // (matches ExMonty's `drive_with_mounts` recovery) instead of `unwrap`-panicking.
    let mut bash = session
        .bash
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    // Thread this exec's back-call target (handler pid + per-call timeout) in as
    // an execution extension, so any custom builtin can reach the right Elixir
    // handler. Harmless when the session has no custom builtins (nothing reads it).
    let target = CallTarget {
        handler,
        timeout: Duration::from_millis(builtin_timeout_ms),
    };
    let extensions = ExecutionExtensions::new().with(target);

    // Publish the target so any mounted `ElixirFs` can reach this exec's handler
    // (FS methods have no execution context). Safe to mutate without the `bash`
    // lock's help because we hold it — this session's execs are serialized. The
    // RAII guard clears it on every exit path, *including* a bashkit panic
    // unwinding through `block_on` (rustler catches the panic, but an explicit
    // clear would be skipped, leaving a stale handler pid that later virtual-FS
    // host calls would wait on).
    *session.fs_target.lock().unwrap_or_else(|p| p.into_inner()) = Some(target);
    let _fs_target_guard = FsTargetGuard(Arc::clone(&session.fs_target));

    let result = runtime().block_on(async { bash.exec_with_extensions(&script, extensions).await });

    encode_exec_result(env, result)
}

/// Read a file from the session's virtual filesystem on the host's behalf,
/// returning `{:ok, binary}` or `{:error, message}`. Operates on the shared FS
/// `Arc` directly (no `bash` lock), so it works even mid-script.
#[rustler::nif(schedule = "DirtyIo")]
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
#[rustler::nif(schedule = "DirtyIo")]
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

/// Map a bashkit `FileType` to the atom the Elixir side uses.
fn file_type_atom(ft: bashkit::FileType) -> rustler::Atom {
    match ft {
        bashkit::FileType::Directory => atoms::dir(),
        bashkit::FileType::Symlink => atoms::symlink(),
        _ => atoms::file(),
    }
}

/// Encode `:ok` / `{:error, message}` for the unit-returning FS host primitives.
fn encode_fs_unit(env: Env<'_>, result: bashkit::Result<()>) -> Term<'_> {
    match result {
        Ok(()) => rustler::types::atom::ok().encode(env),
        Err(e) => {
            let error = rustler::types::atom::error().encode(env);
            let msg = e.to_string().encode(env);
            rustler::types::tuple::make_tuple(env, &[error, msg])
        }
    }
}

/// `stat` a path in the session's filesystem, returning `{:ok, type, size}`
/// (`type` is `:file`/`:dir`/`:symlink`) or `{:error, message}`. Lock-free on the
/// shared FS `Arc`, like `session_read_file`.
#[rustler::nif(schedule = "DirtyIo")]
fn session_stat<'a>(env: Env<'a>, session: ResourceArc<SessionResource>, path: String) -> Term<'a> {
    let fs = Arc::clone(&session.fs.0);
    let result = runtime().block_on(async move { fs.stat(Path::new(&path)).await });

    match result {
        Ok(meta) => {
            let ok = rustler::types::atom::ok().encode(env);
            let ty = file_type_atom(meta.file_type).encode(env);
            let size = meta.size.encode(env);
            rustler::types::tuple::make_tuple(env, &[ok, ty, size])
        }
        Err(e) => {
            let error = rustler::types::atom::error().encode(env);
            let msg = e.to_string().encode(env);
            rustler::types::tuple::make_tuple(env, &[error, msg])
        }
    }
}

/// List a directory in the session's filesystem, returning
/// `{:ok, [{name, type}]}` or `{:error, message}`.
#[rustler::nif(schedule = "DirtyIo")]
fn session_list_dir<'a>(
    env: Env<'a>,
    session: ResourceArc<SessionResource>,
    path: String,
) -> Term<'a> {
    let fs = Arc::clone(&session.fs.0);
    let result = runtime().block_on(async move { fs.read_dir(Path::new(&path)).await });

    match result {
        Ok(entries) => {
            let ok = rustler::types::atom::ok().encode(env);
            let list: Vec<Term> = entries
                .into_iter()
                .map(|e| {
                    let name = e.name.encode(env);
                    let ty = file_type_atom(e.metadata.file_type).encode(env);
                    rustler::types::tuple::make_tuple(env, &[name, ty])
                })
                .collect();
            rustler::types::tuple::make_tuple(env, &[ok, list.encode(env)])
        }
        Err(e) => {
            let error = rustler::types::atom::error().encode(env);
            let msg = e.to_string().encode(env);
            rustler::types::tuple::make_tuple(env, &[error, msg])
        }
    }
}

/// Create a directory in the session's filesystem (`recursive` ≈ `mkdir -p`),
/// returning `:ok` or `{:error, message}`.
#[rustler::nif(schedule = "DirtyIo")]
fn session_mkdir<'a>(
    env: Env<'a>,
    session: ResourceArc<SessionResource>,
    path: String,
    recursive: bool,
) -> Term<'a> {
    let fs = Arc::clone(&session.fs.0);
    let result = runtime().block_on(async move { fs.mkdir(Path::new(&path), recursive).await });
    encode_fs_unit(env, result)
}

/// Remove a file or directory from the session's filesystem (`recursive` to
/// remove a non-empty directory), returning `:ok` or `{:error, message}`.
#[rustler::nif(schedule = "DirtyIo")]
fn session_remove<'a>(
    env: Env<'a>,
    session: ResourceArc<SessionResource>,
    path: String,
    recursive: bool,
) -> Term<'a> {
    let fs = Arc::clone(&session.fs.0);
    let result = runtime().block_on(async move { fs.remove(Path::new(&path), recursive).await });
    encode_fs_unit(env, result)
}

/// Rename/move a path within the session's filesystem, returning `:ok` or
/// `{:error, message}`.
#[rustler::nif(schedule = "DirtyIo")]
fn session_rename<'a>(
    env: Env<'a>,
    session: ResourceArc<SessionResource>,
    from: String,
    to: String,
) -> Term<'a> {
    let fs = Arc::clone(&session.fs.0);
    let result =
        runtime().block_on(async move { fs.rename(Path::new(&from), Path::new(&to)).await });
    encode_fs_unit(env, result)
}

/// Capture the session's interpreter state (shell vars/env/cwd/functions plus
/// in-memory VFS contents) as integrity-protected bytes, returning
/// `{:ok, binary}` or `{:error, message}`.
///
/// `key: Some(_)` produces an HMAC-keyed snapshot for crossing trust boundaries;
/// `None` uses bashkit's public integrity tag (corruption-detecting, not secret).
/// The bytes do NOT carry session config (builtins, virtual_fs, mounts, limits) —
/// resume rebuilds a session with the same capabilities, then `session_restore`s.
/// `DirtyCpu` because serializing a large VFS can take real time, though the call
/// itself is synchronous.
#[rustler::nif(schedule = "DirtyCpu")]
fn session_snapshot<'a>(
    env: Env<'a>,
    session: ResourceArc<SessionResource>,
    exclude_filesystem: bool,
    exclude_functions: bool,
    key: Option<Binary<'a>>,
) -> Term<'a> {
    let bash = session
        .bash
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let options = SnapshotOptions {
        exclude_filesystem,
        exclude_functions,
    };

    let result = match key {
        Some(key) => bash.snapshot_to_bytes_keyed_with_options(key.as_slice(), options),
        None => bash.snapshot_with_options(options),
    };

    match result {
        Ok(bytes) => match OwnedBinary::new(bytes.len()) {
            Some(mut bin) => {
                bin.as_mut_slice().copy_from_slice(&bytes);
                let ok = rustler::types::atom::ok().encode(env);
                let payload = bin.release(env).encode(env);
                rustler::types::tuple::make_tuple(env, &[ok, payload])
            }
            None => {
                let error = rustler::types::atom::error().encode(env);
                let msg = "could not allocate a binary for the snapshot".encode(env);
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

/// Restore previously captured state into this session, returning `:ok` or
/// `{:error, message}`. The session's configured capabilities (builtins,
/// virtual_fs, mounts, limits) are preserved — only shell state and in-memory
/// VFS contents are overwritten. bashkit validates the whole snapshot before
/// mutating, so a bad/tampered/wrong-key snapshot leaves the session untouched
/// and usable. `key` must match how the snapshot was taken (keyed vs plain).
#[rustler::nif(schedule = "DirtyCpu")]
fn session_restore<'a>(
    env: Env<'a>,
    session: ResourceArc<SessionResource>,
    data: Binary<'a>,
    key: Option<Binary<'a>>,
) -> Term<'a> {
    let mut bash = session
        .bash
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    let result = match key {
        Some(key) => bash.restore_snapshot_keyed(data.as_slice(), key.as_slice()),
        None => bash.restore_snapshot(data.as_slice()),
    };

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
