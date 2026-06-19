defmodule ExBashkit.Python do
  @moduledoc """
  The `python` builtin: run sandboxed Python inside a bash session, sharing the
  session's filesystem.

  Enabled per session with `ExBashkit.Session.new(python: true)`, which registers
  `python` (and `python3`) as virtual executables. A script can then run
  `python script.py`, `python -c "…"`, or pipe a program on stdin, and the Python
  reads and writes the **same** virtual filesystem the surrounding bash commands
  use — so `curl … > /data.json` followed by `python transform.py` works the way
  it would in a real shell.

  Requires the optional `:ex_monty` dependency (the sandboxed Python interpreter);
  `python: true` raises if it is not available. Python's filesystem/`os`
  operations are routed to the session via `ExBashkit.Python.SessionFs`; all other
  effects (network, clocks) are denied.

  ## Limitations (v1)

    * `sys.argv` is unsupported (a monty limitation, not ours), so argument-parsing
      scripts can't read their arguments. `python -c "…"` and stdin work fully, and
      `python script.py` runs (it just can't see trailing args).
    * The *script path* of `python path` resolves against the shell's working
      directory, but relative paths used **inside** the Python (e.g.
      `Path("out.txt")`) resolve from the filesystem root, not the shell cwd — use
      absolute paths in Python.
    * If a script prints and then raises, the partial stdout is not returned (only
      the error). `open()` file objects are unsupported; use `pathlib.Path` I/O.
  """

  alias ExBashkit.Session
  alias ExBashkit.Python.SessionFs

  @default_names ["python", "python3"]

  # ── :python option normalization (called from Session.new) ─────────────────

  @doc false
  def normalize(value) when value in [nil, false], do: nil
  def normalize(true), do: normalize([])

  def normalize(opts) when is_list(opts) do
    unless Code.ensure_loaded?(ExMonty) do
      raise ArgumentError,
            ":python requires the optional :ex_monty dependency — add " <>
              "{:ex_monty, \"~> …\"} to your deps to enable the python builtin"
    end

    names =
      case Keyword.get(opts, :names) || Keyword.get(opts, :name) do
        nil ->
          @default_names

        name when is_binary(name) ->
          [name]

        list when is_list(list) ->
          Enum.map(list, &to_string/1)

        other ->
          raise ArgumentError,
                ":python :name/:names must be a string or list, got: #{inspect(other)}"
      end

    %{names: names}
  end

  def normalize(other) do
    raise ArgumentError, ":python must be true, false, or a keyword list, got: #{inspect(other)}"
  end

  @doc false
  def names(nil), do: []
  def names(%{names: names}), do: names

  @doc false
  # Build the `name => handler` builtins map, capturing the (already-built)
  # session and its back-call timeout. The handler reaches the session FS via the
  # lock-free `Session.read_file/2` etc., so it is safe to run mid-`exec/2`.
  def builtins(_session, _timeout, nil), do: %{}

  def builtins(%Session{} = session, timeout, %{names: names}) do
    handler = fn call -> run(session, timeout, call) end
    Map.new(names, fn name -> {name, handler} end)
  end

  # ── the builtin ────────────────────────────────────────────────────────────

  @doc false
  def run(%Session{} = session, timeout, %{args: args, stdin: stdin, env: env} = call) do
    cwd = Map.get(call, :cwd, "/")

    case source(args, stdin, cwd, session) do
      {:ok, code, script_name} -> execute(session, env, timeout, code, script_name)
      {:error, message} -> {:error, message}
    end
  end

  defp execute(session, env, timeout, code, script_name) do
    os = SessionFs.os_handler(session, env)
    limits = %{max_duration_secs: max(timeout / 1000, 0.001)}

    case ExMonty.Sandbox.run(code, os: os, limits: limits, script_name: script_name) do
      {:ok, _value, output} -> {:ok, output}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  # ── source resolution: -c / stdin / a file in the session VFS ──────────────

  defp source(["-c", code | _], _stdin, _cwd, _session), do: {:ok, to_string(code), "-c"}
  defp source(["-c"], _stdin, _cwd, _session), do: {:error, "python: argument to -c is missing\n"}
  defp source([], stdin, _cwd, _session), do: from_stdin(stdin)
  defp source(["-"], stdin, _cwd, _session), do: from_stdin(stdin)

  defp source([path | _], _stdin, cwd, session) do
    if String.starts_with?(path, "-") do
      {:error, "python: unsupported option '#{path}'\n"}
    else
      from_file(session, path, cwd)
    end
  end

  defp from_stdin(stdin) when is_binary(stdin) and stdin != "", do: {:ok, stdin, "<stdin>"}

  defp from_stdin(_),
    do: {:error, "python: no input (interactive mode is not supported)\n"}

  defp from_file(session, path, cwd) do
    full = resolve(path, cwd)

    case Session.read_file(session, full) do
      {:ok, code} -> {:ok, code, Path.basename(full)}
      {:error, _} -> {:error, "python: can't open file '#{path}': No such file or directory\n"}
    end
  end

  # Relative script paths resolve against the shell's working directory (threaded
  # through the back-call as `cwd`), exactly like a real `python p.py` after `cd`.
  defp resolve("/" <> _ = absolute, _cwd), do: absolute
  defp resolve(relative, cwd), do: Path.join(cwd, relative)

  # ── error formatting → Python-ish stderr ───────────────────────────────────

  # Match the exception structurally rather than as `%ExMonty.Exception{}`: a
  # struct pattern would force a *compile-time* dependency on ExMonty, breaking
  # compilation for anyone who hasn't added the optional dep. The module name
  # here is just an atom value, so this needs nothing loaded at compile time.
  defp format_error(%{__struct__: ExMonty.Exception, type: type, message: message}) do
    "#{exception_name(type)}: #{message}\n"
  end

  defp format_error(other), do: "python: #{inspect(other)}\n"

  # Python exception class names from monty's snake_case atoms. A few have
  # acronyms that plain title-casing would mangle (OSError, IOError, …).
  @exception_overrides %{
    os_error: "OSError",
    io_error: "IOError",
    eof_error: "EOFError"
  }

  defp exception_name(type) when is_atom(type) do
    Map.get_lazy(@exception_overrides, type, fn ->
      type |> Atom.to_string() |> String.split("_") |> Enum.map_join(&String.capitalize/1)
    end)
  end
end
