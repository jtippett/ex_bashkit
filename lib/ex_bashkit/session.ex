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
  """

  alias ExBashkit.Result

  @enforce_keys [:ref]
  defstruct [:ref]

  @opaque t :: %__MODULE__{ref: reference()}

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

    session =
      case ExBashkit.Native.session_new(env, cwd, username, hostname, mounts, allowed, limits) do
        {:ok, ref} -> %__MODULE__{ref: ref}
        {:error, message} -> raise ArgumentError, message
      end

    opts |> Keyword.get(:files, %{}) |> seed_files(session)
    session
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
  def exec(%__MODULE__{ref: ref}, script) when is_binary(script) do
    case ExBashkit.Native.session_exec(ref, script) do
      {:ok, {stdout, stderr, exit_code}} ->
        {:ok, %Result{stdout: stdout, stderr: stderr, exit_code: exit_code}}

      {:error, message} ->
        {:error, message}
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
  under a host mount reads the **real host file**.

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
