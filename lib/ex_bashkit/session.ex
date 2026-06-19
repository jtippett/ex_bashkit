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

  @doc """
  Create a new persistent session, optionally seeding its initial state.

  See the module doc for the supported `opts`. Construction is infallible;
  malformed options raise (they are a programmer error).
  """
  @spec new([option]) :: t()
  def new(opts \\ []) when is_list(opts) do
    env = opts |> Keyword.get(:env, []) |> normalize_env()
    cwd = opts |> Keyword.get(:cwd) |> normalize_string()
    username = opts |> Keyword.get(:username) |> normalize_string()
    hostname = opts |> Keyword.get(:hostname) |> normalize_string()

    ref = ExBashkit.Native.session_new(env, cwd, username, hostname)
    %__MODULE__{ref: ref}
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

  # The NIF wants a list of {String, String} pairs; accept a map or keyword list
  # and stringify both halves so `env: [LANG: "C"]` and `env: %{"LANG" => "C"}`
  # behave identically.
  defp normalize_env(env) when is_map(env) or is_list(env) do
    Enum.map(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_string(nil), do: nil
  defp normalize_string(value), do: to_string(value)
end
