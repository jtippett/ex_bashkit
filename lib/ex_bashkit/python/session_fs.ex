defmodule ExBashkit.Python.SessionFs do
  @moduledoc false
  # An `ExMonty.Sandbox` `:os` handler that routes Python's filesystem/`os`
  # operations to a bashkit `Session`'s (shared) virtual filesystem, so Python
  # run via the `python` builtin reads and writes the *same* files a bash step
  # does. Modeled on `ExMonty.PseudoFS`, but backed by the live session instead
  # of an in-memory map — the mirror image of the `:virtual_fs` feature.
  #
  # Returned as a plain `%{op_atom => (args, kwargs -> result)}` map; ops not in
  # the map are denied by ExMonty.Sandbox (default-deny), which is the v1 posture
  # for everything that isn't filesystem/env.

  alias ExBashkit.Session

  # A fixed mtime keeps `stat()` deterministic (matches PseudoFS's default).
  @mtime 1_700_000_000.0

  @doc """
  Build the `:os` handler map for `session`. `env` is the bash environment map
  for the running command (used by `os.getenv`/`os.environ`).
  """
  @spec os_handler(Session.t(), map()) :: %{atom() => (list(), map() -> term())}
  def os_handler(session, env) do
    %{
      read_text: fn [path | _], _kw ->
        case Session.read_file(session, extract_path(path)) do
          {:ok, bin} -> {:ok, bin}
          {:error, _} -> file_not_found(path)
        end
      end,
      read_bytes: fn [path | _], _kw ->
        case Session.read_file(session, extract_path(path)) do
          {:ok, bin} -> {:ok, {:bytes, bin}}
          {:error, _} -> file_not_found(path)
        end
      end,
      write_text: fn [path, content | _], _kw ->
        write(session, extract_path(path), to_string(content))
      end,
      write_bytes: fn
        [path, {:bytes, content} | _], _kw ->
          write(session, extract_path(path), content)

        [path, content | _], _kw when is_binary(content) ->
          write(session, extract_path(path), content)
      end,
      exists: fn [path | _], _kw -> {:ok, exists?(session, extract_path(path))} end,
      is_file: fn [path | _], _kw -> {:ok, type_is(session, extract_path(path), :file)} end,
      is_dir: fn [path | _], _kw -> {:ok, type_is(session, extract_path(path), :dir)} end,
      is_symlink: fn [path | _], _kw -> {:ok, type_is(session, extract_path(path), :symlink)} end,
      stat: fn [path | _], _kw -> stat(session, extract_path(path)) end,
      iterdir: fn [path | _], _kw -> iterdir(session, extract_path(path)) end,
      mkdir: fn [path | _], kw -> mkdir(session, extract_path(path), kw) end,
      unlink: fn [path | _], _kw -> remove(session, extract_path(path), false) end,
      rmdir: fn [path | _], _kw -> remove(session, extract_path(path), false) end,
      rename: fn [path, target | _], _kw ->
        rename(session, extract_path(path), extract_path(target))
      end,
      resolve: fn [path | _], _kw -> {:ok, extract_path(path)} end,
      absolute: fn [path | _], _kw -> {:ok, extract_path(path)} end,
      getenv: fn
        [key | rest], _kw -> {:ok, Map.get(env, key, List.first(rest))}
        _, _ -> {:error, :type_error, "getenv() requires a key"}
      end,
      get_environ: fn _args, _kw -> {:ok, env} end
    }
  end

  # ── routing helpers ────────────────────────────────────────────────────────

  defp write(session, path, content) do
    case Session.write_file(session, path, content) do
      :ok -> {:ok, byte_size(content)}
      {:error, msg} -> {:error, :os_error, msg}
    end
  end

  defp exists?(session, path), do: match?({:ok, _}, Session.stat(session, path))

  defp type_is(session, path, type) do
    match?({:ok, %{type: ^type}}, Session.stat(session, path))
  end

  defp stat(session, path) do
    case Session.stat(session, path) do
      {:ok, %{type: :dir, size: size}} -> {:ok, stat_result(Bitwise.bor(0o040_000, 0o755), size)}
      {:ok, %{size: size}} -> {:ok, stat_result(Bitwise.bor(0o100_000, 0o644), size)}
      {:error, _} -> file_not_found(path)
    end
  end

  defp iterdir(session, path) do
    case Session.list_dir(session, path) do
      {:ok, entries} ->
        {:ok, Enum.map(entries, fn {name, _type} -> {:path, join(path, name)} end)}

      {:error, _} ->
        file_not_found(path)
    end
  end

  defp mkdir(session, path, kw) do
    parents = kw["parents"] == true
    exist_ok = kw["exist_ok"] == true

    cond do
      # Python raises FileExistsError unless exist_ok. bashkit's *recursive* mkdir
      # treats an existing dir as a no-op (Ok), so without this pre-check
      # `mkdir(parents=True)` on an existing dir would wrongly succeed. (Matches
      # PseudoFS, which uses :os_error + "[Errno 17]".)
      not exist_ok and type_is(session, path, :dir) ->
        {:error, :os_error, "[Errno 17] File exists: '#{path}'"}

      true ->
        case Session.mkdir(session, path, parents: parents) do
          :ok -> {:ok, nil}
          {:error, msg} -> {:error, :os_error, msg}
        end
    end
  end

  defp remove(session, path, recursive) do
    case Session.remove(session, path, recursive: recursive) do
      :ok -> {:ok, nil}
      {:error, _} -> file_not_found(path)
    end
  end

  defp rename(session, from, to) do
    case Session.rename(session, from, to) do
      :ok -> {:ok, {:path, to}}
      {:error, msg} -> {:error, :os_error, msg}
    end
  end

  # ── encoding helpers ───────────────────────────────────────────────────────

  defp extract_path({:path, p}), do: p
  defp extract_path(p) when is_binary(p), do: p

  defp file_not_found(path) do
    {:error, :file_not_found_error,
     "[Errno 2] No such file or directory: '#{extract_path(path)}'"}
  end

  defp join(dir, name) do
    if String.ends_with?(dir, "/"), do: dir <> name, else: dir <> "/" <> name
  end

  defp stat_result(mode, size) do
    {:named_tuple, "StatResult",
     [
       {"st_mode", mode},
       {"st_ino", 0},
       {"st_dev", 0},
       {"st_nlink", if(Bitwise.band(mode, 0o040_000) != 0, do: 2, else: 1)},
       {"st_uid", 0},
       {"st_gid", 0},
       {"st_size", size},
       {"st_atime", @mtime},
       {"st_mtime", @mtime},
       {"st_ctime", @mtime}
     ]}
  end
end
