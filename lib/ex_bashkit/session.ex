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

  ## Virtual filesystem

  A session's in-memory filesystem is shared between scripts and the host. Use
  `write_file/3` to place files (e.g. inputs) and `read_file/2` to pull files
  back out (e.g. results a script produced) without going through a script:

      iex> session = ExBashkit.Session.new(files: %{"/in.txt" => "data\\n"})
      iex> {:ok, _} = ExBashkit.Session.exec(session, "wc -l < /in.txt > /out.txt")
      iex> ExBashkit.Session.read_file(session, "/out.txt")
      {:ok, "1\\n"}
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

  @doc """
  Create a new persistent session, optionally seeding its initial state.

  See the module doc for the supported `opts`. Construction is infallible;
  malformed options raise (they are a programmer error). Raises `ArgumentError`
  if a `:files` entry cannot be written (e.g. it violates a filesystem limit).
  """
  @spec new([option]) :: t()
  def new(opts \\ []) when is_list(opts) do
    env = opts |> Keyword.get(:env, []) |> normalize_env()
    cwd = opts |> Keyword.get(:cwd) |> normalize_string()
    username = opts |> Keyword.get(:username) |> normalize_string()
    hostname = opts |> Keyword.get(:hostname) |> normalize_string()

    ref = ExBashkit.Native.session_new(env, cwd, username, hostname)
    session = %__MODULE__{ref: ref}

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
  independent of the session's working directory; pass absolute paths.

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
