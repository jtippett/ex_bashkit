defmodule ExBashkit.Session do
  @moduledoc """
  A persistent, stateful sandbox.

  Unlike `ExBashkit.exec/1` — which runs each script in a fresh interpreter —
  a session is a long-lived `bashkit::Bash` whose state carries across calls:
  environment variables, the current working directory, the in-memory virtual
  filesystem, shell functions, and aliases all persist from one `exec/2` to the
  next, exactly as in an interactive shell.

  The handle is an opaque resource. Hold it for as long as you want the state to
  live; it is reclaimed when it is garbage-collected. A session serializes its
  own calls — concurrent `exec/2` calls on the *same* session run one at a time.

  ## Example

      iex> session = ExBashkit.Session.new()
      iex> {:ok, _} = ExBashkit.Session.exec(session, "export COUNT=1")
      iex> {:ok, result} = ExBashkit.Session.exec(session, "echo $COUNT")
      iex> result.stdout
      "1\\n"

  ## Options

  `new/1` accepts builder options that seed the session's initial state:

    * `:env` - a map or keyword list of environment variables to pre-set. Keys
      and values are stringified (`env: %{"LANG" => "C"}` or `env: [LANG: "C"]`).
    * `:cwd` - the starting working directory (default `/`).
    * `:username` - the virtual username reported by `whoami`/`id`
      (default `"sandbox"`).
    * `:hostname` - the virtual hostname reported by `hostname`/`uname -n`
      (default `"bashkit-sandbox"`).
    * `:files` - a map (or keyword list) of `path => content` to seed into the
      virtual filesystem before the first call, creating parent directories as
      needed. Content is any `t:iodata/0`. Equivalent to calling `write_file/3`
      for each entry.
    * `:mounts` - a list of `{vfs_path, host_path, mode}` tuples mapping a real
      host directory into the sandbox (see "Host mounts" below). `mode` is
      `:read_only` or `:read_write`.
    * `:allowed_mount_paths` - a list of host paths that may be mounted even
      though they fall under a directory bashkit refuses by default (see below).
    * `:limits` - a keyword list or map of resource limits enforced during
      execution (see "Resource limits" below).
    * `:allow_net` - a list of URL patterns the `curl`/`wget`/`http` builtins may
      reach, or `:all` to permit any host (see "Network access" below). Omitted,
      the network is unreachable.
    * `:block_private_ips` - whether to block requests that resolve to private or
      reserved IP ranges (default `true`; see "Network access").
    * `:builtins` - a map of `name => fun` registering Elixir-defined virtual
      executables a script can invoke (see "Custom builtins" below).
    * `:builtin_timeout_ms` - how long a single custom-builtin back-call may run
      before it is abandoned (positive integer, default `30_000`). Also bounds
      `:virtual_fs` back-calls.
    * `:virtual_fs` - a map of `mount_path => backend` mounting Elixir-backed
      filesystems whose reads and writes are serviced by your application (see
      "Virtual filesystem backends" below and `ExBashkit.VirtualFs`).
    * `:python` - `true` (or `[name: ...]`/`[names: [...]]`) to register a
      sandboxed `python`/`python3` builtin that shares the session filesystem.
      Requires the optional `:ex_monty` dependency (see `ExBashkit.Python`).

  ## Virtual filesystem

  A session's in-memory filesystem is shared between scripts and the host. Use
  `write_file/3` to place files (e.g. inputs) and `read_file/2` to pull files
  back out (e.g. results a script produced) without going through a script:

      iex> session = ExBashkit.Session.new(files: %{"/in.txt" => "data\\n"})
      iex> {:ok, _} = ExBashkit.Session.exec(session, "wc -l < /in.txt > /out.txt")
      iex> ExBashkit.Session.read_file(session, "/out.txt")
      {:ok, "1\\n"}

  ## Host mounts

  By default nothing on the real host is reachable. The `:mounts` option maps a
  real host directory into the sandbox's filesystem:

      ExBashkit.Session.new(
        mounts: [
          {"/data", "/srv/app/data", :read_only},
          {"/work", "/tmp/sandbox-work", :read_write}
        ]
      )

    * `:read_only` — scripts can read host files; writes fail.
    * `:read_write` — scripts can read **and modify** real host files. A footgun;
      use a dedicated directory.

  bashkit enforces all isolation: paths are canonicalized, `..` traversal and
  symlinks that escape the mounted directory are rejected, so a mount of
  `/srv/app/data` can never reach `/srv/app/secrets`.

  By default bashkit **refuses to mount sensitive host locations** — `/etc`,
  `/proc`, `/sys`, `/dev`, `/home`, `/Users`, `/private` (which on macOS includes
  temp dirs under `/var/folders`), and paths containing `.ssh`/`.aws`/etc. To
  mount under one deliberately, list a covering prefix in `:allowed_mount_paths`.
  Note this is a *switch*, not additive: once you set `:allowed_mount_paths`, the
  built-in sensitive-path denylist is **off** and the allowlist becomes the sole
  gate — every mount's host path must then sit under some allowlisted prefix.

  A misconfigured mount raises from `new/1` — unknown mode, a missing or
  non-directory host path, or a host path bashkit refuses (sensitive with no
  covering allowlist entry).

  ## Network access

  By default a session cannot reach the network at all — `curl`, `wget`, and
  `http` fail. Grant access with `:allow_net`, an allowlist of URL patterns:

      session =
        ExBashkit.Session.new(
          allow_net: ["https://api.example.com", "https://cdn.example.com/assets"]
        )

      {:ok, result} = ExBashkit.Session.exec(session, "curl -s https://api.example.com/v1/health")

  The allowlist is **default-deny**: only requests whose scheme, host, port, and
  path-prefix match a pattern are permitted; everything else fails. Matching is
  literal (no DNS resolution at match time), and redirects are not followed, so a
  response cannot bounce a script to an unlisted host. `allow_net: :all` lifts the
  allowlist entirely — only safe for fully trusted scripts.

  Independently, requests that resolve to **private or reserved IP ranges**
  (loopback, `10/8`, `172.16/12`, `192.168/16`, link-local, ULA, …) are blocked
  by default, even if the URL is on the allowlist. This stops a script from
  reaching internal services via SSRF / DNS-rebinding. To talk to a private
  address on purpose (e.g. a localhost dev server), set `block_private_ips: false`
  — understand the SSRF exposure before you do.

  ## Resource limits

  bashkit already bounds execution with safe defaults; `:limits` tightens them
  for untrusted scripts. Each key is optional; unset keys keep bashkit's default.
  When a script exceeds a limit, `exec/2` returns `{:error, message}`.

      session = ExBashkit.Session.new(limits: [max_commands: 1_000, timeout_ms: 2_000])

    * `:max_commands` - total commands a script may run (fuel; default 10,000).
    * `:max_loop_iterations` - iterations of any single loop (default 10,000).
    * `:max_total_loop_iterations` - iterations across all loops, defeating the
      nested-loop multiplication trick (default 1,000,000).
    * `:max_function_depth` - recursion depth (default 100).
    * `:max_input_bytes` - maximum script size in bytes (default 10,000,000).
    * `:timeout_ms` - wall-clock execution timeout in milliseconds (default
      30,000; must be ≥ 1). Because a running script holds a dirty scheduler
      thread for its duration, a large `:timeout_ms` under heavy concurrency can
      starve the (bounded) dirty-CPU pool — keep it as tight as the workload allows.

  Count limits must be non-negative integers (a value past the platform maximum
  means "unlimited"); unknown keys raise `ArgumentError`.

  ## Custom builtins

  `:builtins` registers Elixir-defined **virtual executables**: a script line
  `name args…` calls back into your application, which computes the command's
  output. This is how a sandbox reaches capabilities you control — a database
  query, a key/value lookup, an approval prompt — without giving the script real
  process or network access.

      session =
        ExBashkit.Session.new(
          builtins: %{
            "kv_get" => fn call ->
              case Store.fetch(hd(call.args)) do
                {:ok, value} -> {:ok, value <> "\\n"}
                :error -> {:error, "no such key\\n"}
              end
            end
          }
        )

      {:ok, %ExBashkit.Result{stdout: "42\\n"}} =
        ExBashkit.Session.exec(session, "total=$(kv_get answer); echo $total")

  Each builtin is a **1-arity function** receiving one map:

    * `:args` - the command's arguments (a list of strings), excluding the name.
    * `:stdin` - input piped from the previous command (`""` if none).
    * `:env` - the session's environment variables (a `%{String.t => String.t}`).

  It returns a **tagged** result:

    * `{:ok, iodata}` - success; the iodata becomes stdout, exit code `0`.
    * `{:error, iodata}` - failure; the iodata becomes stderr, exit code `1`.
    * `%ExBashkit.Result{}` - full control over stdout, stderr, and exit code.

  Anything else is treated as a contract violation: the command fails (exit `1`)
  with a descriptive stderr message rather than crashing the session.

  **Robustness.** A builtin that raises, or runs longer than `:builtin_timeout_ms`
  (exit `124`), fails only *that command* — the session stays usable.

  **No reentrancy.** A builtin handler must not call `exec/2` on the *same*
  session; that exec already holds the session's lock, so the call would block.
  Driving a *different* session from inside a builtin is fine. Each `exec/2`
  services back-calls from a short-lived process, so builtins run outside the
  caller's process and must not rely on its process dictionary or `self()`.

  ## Virtual filesystem backends

  `:virtual_fs` mounts an **Elixir-backed filesystem** at a vfs path: a script's
  reads and writes under that path are serviced by your application, so "files"
  can be generated on demand or proxied to a real store. It composes with the
  in-memory FS, `:files`, and host `:mounts`.

      session =
        ExBashkit.Session.new(
          virtual_fs: %{
            "/api" => fn
              %{op: :read, path: path} -> {:ok, render(path)}
              _ -> {:error, :enotsup}
            end
          }
        )

      {:ok, %ExBashkit.Result{stdout: out}} =
        ExBashkit.Session.exec(session, "cat /api/users/1.json")

  A backend is a `t:virtual_fs_spec/0` — a module implementing `ExBashkit.VirtualFs`,
  a `{module, arg}` pair, or a single dispatch function for inline use. Paths
  arrive **rooted at the mount**. The same failure model and
  `:builtin_timeout_ms` as custom builtins apply, and the same no-reentrancy
  rule. See `ExBashkit.VirtualFs` for the full contract.
  """

  alias ExBashkit.Result

  @enforce_keys [:ref]
  defstruct [:ref, builtins: %{}, builtin_timeout_ms: 30_000, virtual_fs: %{}]

  @opaque t :: %__MODULE__{
            ref: reference(),
            builtins: %{optional(String.t()) => (map() -> term())},
            builtin_timeout_ms: pos_integer(),
            virtual_fs: %{optional(String.t()) => virtual_fs_spec()}
          }

  @typedoc """
  A virtual-filesystem backend for one mount: a 1-arity function, a module
  implementing `ExBashkit.VirtualFs`, or `{module, arg}`.
  """
  @type virtual_fs_spec :: (map() -> term()) | module() | {module(), term()}

  @type option ::
          {:env, %{optional(String.t() | atom()) => String.t()} | keyword()}
          | {:cwd, Path.t()}
          | {:username, String.t()}
          | {:hostname, String.t()}
          | {:files, %{optional(Path.t()) => iodata()} | [{Path.t(), iodata()}]}
          | {:mounts, [{Path.t(), Path.t(), mount_mode()}]}
          | {:allowed_mount_paths, [Path.t()]}
          | {:limits,
             %{optional(limit_key()) => non_neg_integer()} | [{limit_key(), non_neg_integer()}]}
          | {:allow_net, [String.t()] | :all}
          | {:block_private_ips, boolean()}
          | {:builtins, %{optional(String.t()) => (map() -> term())}}
          | {:builtin_timeout_ms, pos_integer()}
          | {:virtual_fs, %{optional(Path.t()) => virtual_fs_spec()}}
          | {:python, boolean() | keyword()}

  @typedoc "Access mode for a host directory mount."
  @type mount_mode :: :read_only | :read_write

  @typedoc "A resource-limit key accepted by the `:limits` option."
  @type limit_key ::
          :max_commands
          | :max_loop_iterations
          | :max_total_loop_iterations
          | :max_function_depth
          | :max_input_bytes
          | :timeout_ms

  @doc """
  Create a new persistent session, optionally seeding its initial state.

  See the module doc for the supported `opts`. Construction is infallible for
  the in-memory options; malformed options raise (they are a programmer error).
  Raises `ArgumentError` if a `:files` entry cannot be written, or if a `:mounts`
  entry is invalid (unknown mode, or a host path that is missing or not a
  directory).
  """
  @spec new([option]) :: t()
  def new(opts \\ []) when is_list(opts) do
    env = opts |> Keyword.get(:env, []) |> normalize_env()
    cwd = opts |> Keyword.get(:cwd) |> normalize_string()
    username = opts |> Keyword.get(:username) |> normalize_string()
    hostname = opts |> Keyword.get(:hostname) |> normalize_string()
    mounts = opts |> Keyword.get(:mounts, []) |> normalize_mounts()
    allowed = opts |> Keyword.get(:allowed_mount_paths, []) |> Enum.map(&to_string/1)
    limits = opts |> Keyword.get(:limits) |> normalize_limits()
    network = normalize_network(opts)
    builtins = opts |> Keyword.get(:builtins, %{}) |> normalize_builtins()

    builtin_timeout_ms =
      opts |> Keyword.get(:builtin_timeout_ms, 30_000) |> normalize_builtin_timeout()

    virtual_fs = opts |> Keyword.get(:virtual_fs, %{}) |> normalize_virtual_fs()

    python = opts |> Keyword.get(:python) |> ExBashkit.Python.normalize()
    python_names = ExBashkit.Python.names(python)
    validate_python_names!(python_names, builtins)

    session =
      case ExBashkit.Native.session_new(
             env,
             cwd,
             username,
             hostname,
             mounts,
             allowed,
             limits,
             network,
             Map.keys(builtins) ++ python_names,
             Map.keys(virtual_fs)
           ) do
        {:ok, ref} ->
          base = %__MODULE__{
            ref: ref,
            builtins: builtins,
            builtin_timeout_ms: builtin_timeout_ms,
            virtual_fs: virtual_fs
          }

          # The python builtin captures the (built) session so its handler can
          # reach the shared FS via the lock-free read_file/write_file/etc.
          %{
            base
            | builtins:
                Map.merge(builtins, ExBashkit.Python.builtins(base, builtin_timeout_ms, python))
          }

        {:error, message} ->
          raise ArgumentError, message
      end

    opts |> Keyword.get(:files, %{}) |> seed_files(session)
    session
  end

  defp validate_python_names!(python_names, builtins) do
    case Enum.filter(python_names, &Map.has_key?(builtins, &1)) do
      [] ->
        :ok

      clashes ->
        raise ArgumentError,
              "python builtin name(s) #{inspect(clashes)} collide with a :builtins entry; " <>
                "rename the custom builtin or set python: [name: ...]"
    end
  end

  @doc """
  Execute `script` against `session`, mutating it in place.

  Any env/cwd/filesystem/function changes the script makes persist for the next
  call. Returns `{:ok, %ExBashkit.Result{}}` on success — a non-zero `exit_code`
  is still `{:ok, ...}`, just like a real shell — or `{:error, message}` if the
  script could not be parsed or the interpreter itself errored.

  ## Examples

      iex> session = ExBashkit.Session.new()
      iex> {:ok, _} = ExBashkit.Session.exec(session, "cd /tmp")
      iex> {:ok, result} = ExBashkit.Session.exec(session, "pwd")
      iex> result.stdout
      "/tmp\\n"
  """
  @spec exec(t(), String.t()) :: {:ok, Result.t()} | {:error, String.t()}
  def exec(
        %__MODULE__{
          ref: ref,
          builtins: builtins,
          builtin_timeout_ms: timeout,
          virtual_fs: virtual_fs
        },
        script
      )
      when is_binary(script) do
    {handler, cleanup} = start_handler(builtins, virtual_fs)

    try do
      case ExBashkit.Native.session_exec(ref, script, handler, timeout) do
        {:ok, {stdout, stderr, exit_code}} ->
          {:ok, %Result{stdout: stdout, stderr: stderr, exit_code: exit_code}}

        {:error, message} ->
          {:error, message}
      end
    after
      cleanup.()
    end
  end

  @doc """
  Write `content` (any `t:iodata/0`) to `path` in the session's virtual
  filesystem, creating parent directories as needed.

  Returns `:ok`, or `{:error, message}` if the write was rejected (e.g. a
  filesystem limit). The file is immediately visible to subsequent `exec/2`
  calls and to `read_file/2`.

  `path` is resolved from the filesystem **root**, independent of the session's
  working directory (the cwd lives in the interpreter, not the filesystem). Pass
  absolute paths; a relative path like `"out.txt"` is treated as `"/out.txt"`.
  If `path` falls under a `:read_write` host mount, the write reaches the **real
  host disk** (and fails under a `:read_only` mount), just as it would for a script.

  This targets the in-memory and host-mount filesystem; it is not the way to feed
  a `:virtual_fs` mount (those are driven by your backend, only while a script
  runs). A path under a `:virtual_fs` mount returns `{:error, _}` here.

  ## Examples

      iex> session = ExBashkit.Session.new()
      iex> ExBashkit.Session.write_file(session, "/etc/motd", "welcome\\n")
      :ok
      iex> {:ok, result} = ExBashkit.Session.exec(session, "cat /etc/motd")
      iex> result.stdout
      "welcome\\n"
  """
  @spec write_file(t(), Path.t(), iodata()) :: :ok | {:error, String.t()}
  def write_file(%__MODULE__{ref: ref}, path, content) do
    ExBashkit.Native.session_write_file(ref, to_string(path), IO.iodata_to_binary(content))
  end

  @doc """
  Read the contents of `path` from the session's virtual filesystem.

  Returns `{:ok, binary}` — including for files a script wrote — or
  `{:error, message}` if the file does not exist or cannot be read. The result
  is a raw binary, so it round-trips arbitrary (including non-UTF-8) content.

  As with `write_file/3`, `path` is resolved from the filesystem **root**,
  independent of the session's working directory; pass absolute paths. A `path`
  under a host mount reads the **real host file**; a path under a `:virtual_fs`
  mount is not serviced here and returns `{:error, _}`.

  ## Examples

      iex> session = ExBashkit.Session.new()
      iex> {:ok, _} = ExBashkit.Session.exec(session, "echo result > /out.txt")
      iex> ExBashkit.Session.read_file(session, "/out.txt")
      {:ok, "result\\n"}
  """
  @spec read_file(t(), Path.t()) :: {:ok, binary()} | {:error, String.t()}
  def read_file(%__MODULE__{ref: ref}, path) do
    ExBashkit.Native.session_read_file(ref, to_string(path))
  end

  @typedoc "A filesystem entry's kind, as reported by `stat/2` and `list_dir/2`."
  @type fs_type :: :file | :dir | :symlink

  @doc """
  Return metadata for `path` in the session's filesystem.

  `{:ok, %{type: :file | :dir | :symlink, size: non_neg_integer()}}`, or
  `{:error, message}` if the path does not exist. Like `read_file/2`, it resolves
  from the filesystem root and reads through host mounts; it is lock-free, so it
  also works while a script is running.

  ## Examples

      iex> session = ExBashkit.Session.new()
      iex> {:ok, _} = ExBashkit.Session.exec(session, "printf 12345 > /f")
      iex> ExBashkit.Session.stat(session, "/f")
      {:ok, %{type: :file, size: 5}}
  """
  @spec stat(t(), Path.t()) ::
          {:ok, %{type: fs_type(), size: non_neg_integer()}} | {:error, String.t()}
  def stat(%__MODULE__{ref: ref}, path) do
    case ExBashkit.Native.session_stat(ref, to_string(path)) do
      {:ok, type, size} -> {:ok, %{type: type, size: size}}
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  List the entries of directory `path` in the session's filesystem.

  `{:ok, [{name, :file | :dir | :symlink}]}` (names are the immediate children,
  not full paths), or `{:error, message}` if `path` is not a readable directory.

  ## Examples

      iex> session = ExBashkit.Session.new()
      iex> {:ok, _} = ExBashkit.Session.exec(session, "mkdir /d; echo x > /d/a.txt")
      iex> ExBashkit.Session.list_dir(session, "/d")
      {:ok, [{"a.txt", :file}]}
  """
  @spec list_dir(t(), Path.t()) :: {:ok, [{String.t(), fs_type()}]} | {:error, String.t()}
  def list_dir(%__MODULE__{ref: ref}, path) do
    ExBashkit.Native.session_list_dir(ref, to_string(path))
  end

  @doc """
  Create directory `path` in the session's filesystem.

  Returns `:ok` or `{:error, message}`. With `parents: true` it creates any
  missing parent directories (like `mkdir -p`) and succeeds if the directory
  already exists; without it, a missing parent is an error.

  ## Options

    * `:parents` - create missing parents (default `false`).
  """
  @spec mkdir(t(), Path.t(), keyword()) :: :ok | {:error, String.t()}
  def mkdir(%__MODULE__{ref: ref}, path, opts \\ []) when is_list(opts) do
    parents = opts |> Keyword.get(:parents, false) |> truthy!(:parents)
    ExBashkit.Native.session_mkdir(ref, to_string(path), parents)
  end

  @doc """
  Remove `path` from the session's filesystem.

  Returns `:ok` or `{:error, message}`. Removing a non-empty directory requires
  `recursive: true`.

  ## Options

    * `:recursive` - remove a directory and its contents (default `false`).
  """
  @spec remove(t(), Path.t(), keyword()) :: :ok | {:error, String.t()}
  def remove(%__MODULE__{ref: ref}, path, opts \\ []) when is_list(opts) do
    recursive = opts |> Keyword.get(:recursive, false) |> truthy!(:recursive)
    ExBashkit.Native.session_remove(ref, to_string(path), recursive)
  end

  @doc """
  Rename/move `from` to `to` within the session's filesystem.

  Returns `:ok` or `{:error, message}`.
  """
  @spec rename(t(), Path.t(), Path.t()) :: :ok | {:error, String.t()}
  def rename(%__MODULE__{ref: ref}, from, to) do
    ExBashkit.Native.session_rename(ref, to_string(from), to_string(to))
  end

  @doc """
  Capture the session's interpreter state as a binary you can persist and later
  reload with `restore/3`.

  The snapshot carries **shell state** (variables, exported env, cwd, arrays,
  aliases, traps, and — unless excluded — functions) and the **in-memory
  filesystem contents**. It is taken at a command boundary; there is no
  pause-mid-command.

  It does **not** carry session *configuration*: custom `:builtins`,
  `:virtual_fs` backends, host `:mounts`, `:limits`, or network settings. Those
  are live Elixir processes / builder config, not interpreter state. To resume,
  build a fresh session with the **same capabilities** and `restore/3` the bytes
  into it (see `restore/3`).

  Returns `{:ok, binary}` or `{:error, message}`.

  ## Options

    * `:key` — a binary secret. Produces an HMAC-keyed snapshot for crossing a
      **trust boundary** (network, shared storage, untrusted storage). Restore
      must supply the same key; a wrong key or tampered bytes are rejected.
      Without a key, bashkit's integrity tag detects accidental corruption only
      (it is public, not a forgery defense).
    * `:exclude_filesystem` — when `true`, capture shell state only (skip VFS
      contents). Default `false`.
    * `:exclude_functions` — when `true`, skip shell functions (avoids cloning
      AST-backed state). Default `false`.

  ## Examples

      iex> session = ExBashkit.Session.new()
      iex> {:ok, %ExBashkit.Result{}} = ExBashkit.Session.exec(session, "x=42")
      iex> {:ok, bytes} = ExBashkit.Session.snapshot(session)
      iex> is_binary(bytes)
      true
  """
  @spec snapshot(t(), keyword()) :: {:ok, binary()} | {:error, String.t()}
  def snapshot(%__MODULE__{ref: ref}, opts \\ []) when is_list(opts) do
    key = snapshot_key(opts)

    exclude_filesystem =
      opts |> Keyword.get(:exclude_filesystem, false) |> truthy!(:exclude_filesystem)

    exclude_functions =
      opts |> Keyword.get(:exclude_functions, false) |> truthy!(:exclude_functions)

    ExBashkit.Native.session_snapshot(ref, exclude_filesystem, exclude_functions, key)
  end

  @doc """
  Restore previously captured state (from `snapshot/2`) into this session,
  returning `{:ok, session}` or `{:error, message}`.

  Restore overwrites the session's shell state and in-memory filesystem contents
  while **preserving the capabilities `session` was built with** — its custom
  `:builtins`, `:virtual_fs` backends, host `:mounts`, and `:limits` survive. The
  intended flow is therefore:

      {:ok, bytes} = ExBashkit.Session.snapshot(original)
      # ...later, or on another node...
      resumed = ExBashkit.Session.new(builtins: same, virtual_fs: same, limits: same)
      {:ok, resumed} = ExBashkit.Session.restore(resumed, bytes)

  bashkit validates the whole snapshot before mutating anything, so a malformed,
  tampered, or wrong-key snapshot returns `{:error, _}` and leaves the session
  untouched and usable. Keying is symmetric and all-or-nothing: bytes taken with
  a `:key` must be restored with the **same** key, and plain bytes must be
  restored without one — a mismatch is an `{:error, _}`.

  ## Options

    * `:key` — the binary secret the snapshot was taken with (see `snapshot/2`).

  ## Examples

      iex> session = ExBashkit.Session.new()
      iex> {:ok, %ExBashkit.Result{}} = ExBashkit.Session.exec(session, "x=42")
      iex> {:ok, bytes} = ExBashkit.Session.snapshot(session)
      iex> fresh = ExBashkit.Session.new()
      iex> {:ok, fresh} = ExBashkit.Session.restore(fresh, bytes)
      iex> {:ok, result} = ExBashkit.Session.exec(fresh, "echo $x")
      iex> result.stdout
      "42\\n"
  """
  @spec restore(t(), binary(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def restore(%__MODULE__{ref: ref} = session, data, opts \\ [])
      when is_binary(data) and is_list(opts) do
    key = snapshot_key(opts)

    case ExBashkit.Native.session_restore(ref, data, key) do
      :ok -> {:ok, session}
      {:error, message} -> {:error, message}
    end
  end

  # A snapshot key, if given, must be a non-empty binary; nil means the unkeyed
  # path. An empty key is rejected on purpose: bashkit's HMAC accepts a zero-length
  # key, so `key: ""` would silently take the "keyed" path while providing no
  # forgery protection at all — exactly the trust-boundary illusion this guards
  # against (a set-but-empty env var is the classic way to hit it).
  defp snapshot_key(opts) do
    case Keyword.get(opts, :key) do
      nil -> nil
      key when is_binary(key) and byte_size(key) > 0 -> key
      "" -> raise ArgumentError, ":key must be a non-empty binary (an empty key is not a secret)"
      other -> raise ArgumentError, ":key must be a binary, got: #{inspect(other)}"
    end
  end

  defp truthy!(value, _opt) when is_boolean(value), do: value

  defp truthy!(value, opt) do
    raise ArgumentError, "#{inspect(opt)} must be a boolean, got: #{inspect(value)}"
  end

  # Normalize :allow_net / :block_private_ips into the plain map the NIF decodes:
  #   %{}                                         -> no network (default deny)
  #   %{allow_all: true, block_private_ips: bool} -> allow every host
  #   %{patterns: [..], block_private_ips: bool}  -> allow only matching URLs
  defp normalize_network(opts) do
    block_private_ips = normalize_block_private_ips(Keyword.get(opts, :block_private_ips, true))

    case Keyword.get(opts, :allow_net) do
      nil ->
        %{}

      :all ->
        %{allow_all: true, block_private_ips: block_private_ips}

      patterns when is_list(patterns) ->
        case Enum.map(patterns, &normalize_net_pattern/1) do
          # An empty allowlist denies everything — same as no network.
          [] -> %{}
          patterns -> %{patterns: patterns, block_private_ips: block_private_ips}
        end

      other ->
        raise ArgumentError,
              ":allow_net must be a list of URL patterns or :all, got: #{inspect(other)}"
    end
  end

  # bashkit matches an allowlist pattern against a request URL's scheme, host,
  # port and path-prefix, so a pattern with no scheme or host can never match any
  # real request — it would be a silent no-op (a deny that looks like a typo).
  # Reject those loudly rather than hand bashkit an entry that allows nothing.
  defp normalize_net_pattern(pattern) when is_binary(pattern) do
    uri = URI.parse(pattern)

    if blank?(uri.scheme) or blank?(uri.host) do
      raise ArgumentError,
            "each :allow_net pattern must be a URL like \"https://host[:port][/path]\", " <>
              "got: #{inspect(pattern)}"
    end

    pattern
  end

  defp normalize_net_pattern(other) do
    raise ArgumentError,
          "each :allow_net pattern must be a URL string, got: #{inspect(other)}"
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp normalize_block_private_ips(value) when is_boolean(value), do: value

  defp normalize_block_private_ips(other) do
    raise ArgumentError, ":block_private_ips must be true or false, got: #{inspect(other)}"
  end

  # --- back-call handling (custom builtins + virtual filesystems) -----------

  # With neither builtins nor virtual filesystems there can be no back-call, so
  # no handler process is needed; the pid we hand the NIF is never used.
  defp start_handler(builtins, virtual_fs)
       when map_size(builtins) == 0 and map_size(virtual_fs) == 0 do
    {self(), fn -> :ok end}
  end

  # Otherwise spawn a short-lived process to service back-calls for the duration
  # of one `exec/2`. It is linked so it dies with the caller (no orphan), and we
  # unlink-then-kill on teardown so our own kill never propagates to the caller.
  defp start_handler(builtins, virtual_fs) do
    pid = spawn_link(fn -> handler_loop(builtins, virtual_fs) end)

    cleanup = fn ->
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end

    {pid, cleanup}
  end

  defp handler_loop(builtins, virtual_fs) do
    receive do
      {:bashkit_call, req_id, name, args, stdin, env_pairs, cwd} ->
        # Service the builtin in a child process so THIS loop stays free to
        # receive the nested FS back-calls a builtin may trigger — e.g. the
        # `python` builtin reading a `:virtual_fs` mount routes through this same
        # handler, which would otherwise deadlock (the loop can't recv the
        # `{:bashkit_fs, ...}` while it's blocked running the builtin). bashkit
        # runs commands one at a time, so at most one builtin is in flight per
        # exec. `invoke_builtin` try/rescue/catches everything and always replies,
        # so the linked child exits normally (the link never carries a crash) and
        # is torn down with the handler.
        spawn_link(fn ->
          {stdout, stderr, exit_code} =
            invoke_builtin(builtins, name, args, stdin, env_pairs, cwd)

          ExBashkit.Native.builtin_reply(req_id, stdout, stderr, exit_code)
        end)

        handler_loop(builtins, virtual_fs)

      {:bashkit_fs, req_id, mount, op, path, data, recursive} ->
        reply = invoke_fs(Map.fetch!(virtual_fs, mount), op, path, data, recursive)
        ExBashkit.Native.fs_reply(req_id, reply)
        handler_loop(builtins, virtual_fs)
    end
  end

  # Run one builtin and normalize its result to {stdout, stderr, exit_code}. A
  # raise, throw, or malformed return becomes a failed command (exit 1) with a
  # descriptive stderr — never a crashed handler or a wedged session.
  defp invoke_builtin(builtins, name, args, stdin, env_pairs, cwd) do
    call = %{args: args, stdin: stdin, env: Map.new(env_pairs), cwd: cwd}

    try do
      builtins |> Map.fetch!(name) |> apply([call]) |> normalize_builtin_return(name)
    rescue
      e -> {"", "#{name}: builtin raised: #{Exception.message(e)}\n", 1}
    catch
      kind, reason -> {"", "#{name}: builtin #{kind}: #{inspect(reason)}\n", 1}
    end
  end

  defp normalize_builtin_return({:ok, io}, _name), do: {IO.iodata_to_binary(io), "", 0}
  defp normalize_builtin_return({:error, io}, _name), do: {"", IO.iodata_to_binary(io), 1}

  defp normalize_builtin_return(%Result{stdout: out, stderr: err, exit_code: code}, _name)
       when is_integer(code) do
    # Mask to a byte like a real shell (exit codes are mod 256). This is also a
    # safety net: the reply NIF takes an i32, so an out-of-range integer here
    # would otherwise raise in the handler process and (being linked) take the
    # caller down — exactly the "a builtin must never wedge the session" hole.
    {IO.iodata_to_binary(out || ""), IO.iodata_to_binary(err || ""), Bitwise.band(code, 0xFF)}
  end

  defp normalize_builtin_return(other, name) do
    {"", "#{name}: builtin returned an invalid value: #{inspect(other)}\n", 1}
  end

  # Validate the :builtins map: string names mapped to arity-1 functions.
  defp normalize_builtins(builtins) when is_map(builtins) or is_list(builtins) do
    map = Map.new(builtins)

    Enum.each(map, fn {name, fun} ->
      # A builtin name must be a single shell token — a name with whitespace
      # could never be invoked from a script, so reject it loudly rather than
      # register a dead entry.
      unless is_binary(name) and Regex.match?(~r/^\S+$/, name) do
        raise ArgumentError,
              "builtin name must be a non-empty string with no whitespace, got: #{inspect(name)}"
      end

      unless is_function(fun, 1) do
        raise ArgumentError,
              "builtin #{inspect(name)} must be a 1-arity function, got: #{inspect(fun)}"
      end
    end)

    map
  end

  defp normalize_builtins(other) do
    raise ArgumentError, ":builtins must be a map of name => function, got: #{inspect(other)}"
  end

  defp normalize_builtin_timeout(ms) when is_integer(ms) and ms > 0, do: ms

  defp normalize_builtin_timeout(other) do
    raise ArgumentError, ":builtin_timeout_ms must be a positive integer, got: #{inspect(other)}"
  end

  # --- virtual filesystem back-call handling --------------------------------

  # Run one FS operation against a mount's backend and normalize its return into
  # the wire reply the `fs_reply` NIF decodes. A raise/throw/bad-shape becomes an
  # `{:error, _}` for that op — never a crashed handler or a wedged session.
  defp invoke_fs(spec, op, path, data, recursive) do
    spec
    |> dispatch_fs(op, path, data, recursive)
    |> normalize_fs_reply(op)
  rescue
    e -> {:error, "#{op}: #{Exception.message(e)}"}
  catch
    kind, reason -> {:error, "#{op}: #{kind} #{inspect(reason)}"}
  end

  defp dispatch_fs(fun, op, path, data, recursive) when is_function(fun, 1) do
    fun.(fs_request(op, path, data, recursive))
  end

  defp dispatch_fs({module, arg}, op, path, data, recursive) do
    fs_apply(module, arg, op, path, data, recursive)
  end

  defp dispatch_fs(module, op, path, data, recursive) when is_atom(module) do
    fs_apply(module, nil, op, path, data, recursive)
  end

  defp fs_request(:write, path, data, _r), do: %{op: :write, path: path, data: data}
  defp fs_request(:append, path, data, _r), do: %{op: :append, path: path, data: data}

  defp fs_request(:mkdir, path, _d, recursive),
    do: %{op: :mkdir, path: path, recursive: recursive}

  defp fs_request(:remove, path, _d, recursive),
    do: %{op: :remove, path: path, recursive: recursive}

  defp fs_request(op, path, _d, _r), do: %{op: op, path: path}

  defp fs_apply(m, arg, :read, path, _d, _r), do: m.read(arg, path)
  defp fs_apply(m, arg, :write, path, data, _r), do: m.write(arg, path, data)
  defp fs_apply(m, arg, :append, path, data, _r), do: m.append(arg, path, data)
  defp fs_apply(m, arg, :mkdir, path, _d, recursive), do: m.mkdir(arg, path, recursive)
  defp fs_apply(m, arg, :remove, path, _d, recursive), do: m.remove(arg, path, recursive)
  defp fs_apply(m, arg, :list, path, _d, _r), do: m.list(arg, path)
  defp fs_apply(m, arg, :stat, path, _d, _r), do: m.stat(arg, path)

  # Canonical wire replies decoded by the `fs_reply` NIF:
  #   :ok | {:ok_bytes, bin} | {:ok_list, [{name, is_dir?}]} | {:ok_stat, is_dir?, size}
  #   | {:error, reason_string}
  defp normalize_fs_reply(:ok, _op), do: :ok
  defp normalize_fs_reply({:ok, content}, :read), do: {:ok_bytes, IO.iodata_to_binary(content)}

  defp normalize_fs_reply({:ok, entries}, :list) when is_list(entries),
    do: {:ok_list, Enum.map(entries, &fs_entry/1)}

  defp normalize_fs_reply({:ok, %{type: type, size: size}}, :stat)
       when type in [:file, :dir] and is_integer(size) and size >= 0,
       do: {:ok_stat, type == :dir, size}

  defp normalize_fs_reply({:error, reason}, _op), do: {:error, fs_reason(reason)}

  defp normalize_fs_reply(other, op),
    do: {:error, "#{op}: backend returned an invalid value: #{inspect(other)}"}

  defp fs_entry(name) when is_binary(name), do: {name, false}
  defp fs_entry({name, :dir}), do: {to_string(name), true}
  defp fs_entry({name, :file}), do: {to_string(name), false}
  defp fs_entry({name, _other}), do: {to_string(name), false}

  defp fs_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp fs_reason(reason) when is_binary(reason), do: reason
  defp fs_reason(reason), do: inspect(reason)

  # Validate the :virtual_fs map: absolute non-root mount paths => a 1-arity
  # function, a module, or a {module, arg} tuple.
  defp normalize_virtual_fs(virtual_fs) when is_map(virtual_fs) or is_list(virtual_fs) do
    Map.new(virtual_fs, fn {path, spec} ->
      path = to_string(path)

      unless String.starts_with?(path, "/") and path != "/" do
        raise ArgumentError,
              ":virtual_fs mount path must be an absolute path other than \"/\", " <>
                "got: #{inspect(path)}"
      end

      unless valid_fs_spec?(spec) do
        raise ArgumentError,
              ":virtual_fs backend for #{inspect(path)} must be a 1-arity function, a module, " <>
                "or {module, arg}, got: #{inspect(spec)}"
      end

      {path, spec}
    end)
  end

  defp normalize_virtual_fs(other) do
    raise ArgumentError,
          ":virtual_fs must be a map of mount_path => backend, got: #{inspect(other)}"
  end

  defp valid_fs_spec?(spec) when is_function(spec, 1), do: true
  defp valid_fs_spec?({module, _arg}), do: fs_module?(module)
  defp valid_fs_spec?(spec), do: fs_module?(spec)

  # A backend module must actually exist (catches typos and rejects booleans/
  # non-module atoms up front, rather than failing at the first back-call).
  defp fs_module?(module) when is_atom(module) and not is_nil(module) and not is_boolean(module),
    do: Code.ensure_loaded?(module)

  defp fs_module?(_), do: false

  @limit_keys ~w(max_commands max_loop_iterations max_total_loop_iterations
                 max_function_depth max_input_bytes timeout_ms)a

  # Validate and collect :limits into a plain map of known keys for the NIF.
  defp normalize_limits(nil), do: %{}

  defp normalize_limits(limits) when is_list(limits) or is_map(limits) do
    map = Map.new(limits)

    Enum.each(map, fn {key, value} ->
      unless key in @limit_keys do
        raise ArgumentError,
              "unknown limit #{inspect(key)}; valid limits: #{inspect(@limit_keys)}"
      end

      unless is_integer(value) and value >= 0 do
        raise ArgumentError,
              "limit #{inspect(key)} must be a non-negative integer, got: #{inspect(value)}"
      end
    end)

    # `timeout_ms: 0` would time out *every* exec immediately (even `echo hi`),
    # unlike the count limits where 0 is a meaningful strict cap. Reject it.
    if Map.get(map, :timeout_ms) == 0 do
      raise ArgumentError, "limit :timeout_ms must be at least 1 (0 would time out immediately)"
    end

    map
  end

  defp normalize_limits(other) do
    raise ArgumentError, ":limits must be a keyword list or map, got: #{inspect(other)}"
  end

  # Stringify each {vfs, host, mode} mount tuple for the NIF; `to_string/1`
  # accepts the mode as an atom (:read_only) or a string. The NIF validates the
  # mode and host path; here we validate the shape and the vfs mount point.
  defp normalize_mounts(mounts) when is_list(mounts), do: Enum.map(mounts, &normalize_mount/1)

  defp normalize_mounts(other) do
    raise ArgumentError,
          ":mounts must be a list of {vfs_path, host_path, mode} tuples, got: #{inspect(other)}"
  end

  defp normalize_mount({vfs, host, mode}) do
    vfs = to_string(vfs)

    unless String.starts_with?(vfs, "/") and vfs != "/" do
      raise ArgumentError,
            "mount vfs_path must be an absolute path other than \"/\", got: #{inspect(vfs)}"
    end

    {vfs, to_string(host), to_string(mode)}
  end

  defp normalize_mount(other) do
    raise ArgumentError,
          "each :mounts entry must be a {vfs_path, host_path, mode} tuple, got: #{inspect(other)}"
  end

  # Seed initial files by writing each one; a failed seed is a programmer error.
  defp seed_files(files, session) when is_map(files) or is_list(files) do
    Enum.each(files, fn {path, content} ->
      case write_file(session, path, content) do
        :ok ->
          :ok

        {:error, reason} ->
          raise ArgumentError,
                "failed to seed file #{inspect(to_string(path))}: #{inspect(reason)}"
      end
    end)
  end

  # The NIF wants a list of {String, String} pairs; accept a map or keyword list
  # and stringify both halves so `env: [LANG: "C"]` and `env: %{"LANG" => "C"}`
  # behave identically.
  defp normalize_env(env) when is_map(env) or is_list(env) do
    Enum.map(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_string(nil), do: nil
  defp normalize_string(value), do: to_string(value)
end
