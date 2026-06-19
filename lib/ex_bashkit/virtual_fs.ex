defmodule ExBashkit.VirtualFs do
  @moduledoc """
  Behaviour for an Elixir-backed virtual filesystem mounted into a session.

  A `:virtual_fs` mount routes a script's filesystem operations under a vfs path
  into your application: "files" can be generated on demand or proxied to a real
  backing store. Register a backend with `ExBashkit.Session.new/1`:

      ExBashkit.Session.new(virtual_fs: %{"/api" => {MyFs, config}})

  Each callback receives the per-mount `arg` (the `config` in `{MyFs, config}`,
  or `nil` for a bare `MyFs`) and a `path` **rooted at the mount** — for a mount
  at `/api`, a read of `/api/users/1.json` arrives as `/users/1.json`, and the
  mount root as `/`.

  ## Implementing a backend

      defmodule MyFs do
        use ExBashkit.VirtualFs

        @impl true
        def read(config, path), do: {:ok, render(config, path)}

        @impl true
        def list(config, _path), do: {:ok, keys(config)}
      end

  `use ExBashkit.VirtualFs` provides default implementations for every callback,
  so you implement only what your backend supports. Defaults:

    * mutating/listing callbacks (`write`, `append`, `mkdir`, `remove`, `list`)
      return `{:error, :enotsup}`;
    * `read` returns `{:error, :enotsup}`;
    * `stat` is **derived from `read/2`** — a backend that implements only
      `read/2` gets working `cat`, `stat`, and `test -f` for files for free (at
      the cost of fetching content to size it; override `stat/2` to avoid that).

  ## Return values

  All callbacks return tagged results. `reason` is an errno-style atom
  (`:enoent`, `:eacces`, `:eexist`, `:eisdir`, `:enotdir`, `:enotsup`) or a
  string, surfaced to the script as the matching filesystem error.

  ## Function form

  For quick or inline backends you may pass a single arity-1 function instead of
  a module. It receives a request map and returns the same tagged results:

      virtual_fs: %{
        "/api" => fn
          %{op: :read, path: path}        -> {:ok, render(path)}
          %{op: :write, path: p, data: d} -> Store.put(p, d)
          %{op: :list, path: _}           -> {:ok, Store.keys()}
          _                               -> {:error, :enotsup}
        end
      }

  The request map always has `:op` and `:path`; `:write`/`:append` also carry
  `:data`, and `:mkdir`/`:remove` carry `:recursive`.

  ## What the shell does to each operation

  | Script | Callback | Notes |
  |--------|----------|-------|
  | `cat f`, `source f`, `$(<f)` | `read` | |
  | `echo x > f` | `write` | truncating write |
  | `echo x >> f` | `append` | |
  | `ls d` | `list` | each `read_dir` entry |
  | `rm f`, `rm -r d` | `remove` | `recursive` set for `-r` |
  | `mkdir d`, `mkdir -p a/b` | `mkdir` | `recursive` set for `-p` |
  | `test -e f`, `[ -f f ]`, tab-completion | `stat` | existence/type checks |

  ## Examples

  ### A read-only generator (function form)

  Serve computed "files" — nothing is stored; content is produced on read. Only
  `read` is needed; `use`'s derived `stat` makes `cat` and `test -f` work, and
  `list` makes `ls` work.

      transform =
        fn
          %{op: :read, path: "/upper/" <> word} -> {:ok, String.upcase(word) <> "\\n"}
          %{op: :read, path: "/reverse/" <> word} -> {:ok, String.reverse(word) <> "\\n"}
          %{op: :read, path: _} -> {:error, :enoent}
          %{op: :list, path: "/"} -> {:ok, [{"upper", :dir}, {"reverse", :dir}]}
          _ -> {:error, :enotsup}
        end

      session = ExBashkit.Session.new(virtual_fs: %{"/x" => transform})
      {:ok, %{stdout: "HELLO\\n"}} = ExBashkit.Session.exec(session, "cat /x/upper/hello")

  ### A read-write store (behaviour form)

  Back a mount with real state — here an `Agent`-held map, passed as the
  per-mount `arg` via `{KvFs, store}`. Implementing `read`/`write`/`remove`/`list`
  is enough; `stat` (and thus `exists`) is derived from `read`.

      defmodule KvFs do
        use ExBashkit.VirtualFs

        @impl true
        def read(store, "/" <> key) do
          case Agent.get(store, &Map.get(&1, key)) do
            nil -> {:error, :enoent}
            value -> {:ok, value}
          end
        end

        @impl true
        def write(store, "/" <> key, data) do
          Agent.update(store, &Map.put(&1, key, data))
          :ok
        end

        @impl true
        def remove(store, "/" <> key, _recursive) do
          Agent.update(store, &Map.delete(&1, key))
          :ok
        end

        @impl true
        def list(store, "/"), do: {:ok, Agent.get(store, &Map.keys(&1))}
      end

      {:ok, store} = Agent.start_link(fn -> %{} end)
      session = ExBashkit.Session.new(virtual_fs: %{"/kv" => {KvFs, store}})

      {:ok, _} = ExBashkit.Session.exec(session, "echo 42 > /kv/answer")
      {:ok, %{stdout: "42\\n"}} = ExBashkit.Session.exec(session, "cat /kv/answer")

  ### Proxying to a real backend

  Because a backend is just Elixir, `read`/`list`/`write` can delegate to anything
  your app already has — a database, an HTTP API, an object store:

      defmodule DocsFs do
        use ExBashkit.VirtualFs

        @impl true
        def read(_arg, "/" <> slug) do
          case MyApp.Docs.fetch(slug) do
            {:ok, doc} -> {:ok, doc.body}
            :error -> {:error, :enoent}
          end
        end

        @impl true
        def list(_arg, "/"), do: {:ok, MyApp.Docs.all_slugs()}
      end

  A script can then `grep`, `cat`, and pipe over your data as if it were files —
  with no real disk or process access.

  ## Notes

    * `exists` is derived from `stat/2`; the mount root always stats as a
      directory.
    * `rename`, `copy`, `symlink`, and `read_link` are not proxied in this
      version (so `mv`/`cp` *across* a virtual mount are unsupported); `chmod` is
      a silent no-op.
    * A backend must not call `ExBashkit.Session.exec/2` on the same session that
      triggered the operation (it would deadlock on the session lock).
  """

  @typedoc "A path rooted at the mount, e.g. `/users/1.json` or `/`."
  @type path :: String.t()

  @typedoc "An errno-style atom or a free-form string."
  @type reason ::
          :enoent | :eacces | :eexist | :eisdir | :enotdir | :enotsup | atom() | String.t()

  @typedoc "A directory entry: a name, or a name tagged with its type."
  @type entry :: String.t() | {String.t(), :file | :dir}

  @callback read(arg :: term(), path()) :: {:ok, iodata()} | {:error, reason()}
  @callback write(arg :: term(), path(), data :: binary()) :: :ok | {:error, reason()}
  @callback append(arg :: term(), path(), data :: binary()) :: :ok | {:error, reason()}
  @callback mkdir(arg :: term(), path(), recursive :: boolean()) :: :ok | {:error, reason()}
  @callback remove(arg :: term(), path(), recursive :: boolean()) :: :ok | {:error, reason()}
  @callback list(arg :: term(), path()) :: {:ok, [entry()]} | {:error, reason()}
  @callback stat(arg :: term(), path()) ::
              {:ok, %{type: :file | :dir, size: non_neg_integer()}} | {:error, reason()}

  @optional_callbacks read: 2, write: 3, append: 3, mkdir: 3, remove: 3, list: 2, stat: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour ExBashkit.VirtualFs

      def read(_arg, _path), do: {:error, :enotsup}
      def write(_arg, _path, _data), do: {:error, :enotsup}
      def append(_arg, _path, _data), do: {:error, :enotsup}
      def mkdir(_arg, _path, _recursive), do: {:error, :enotsup}
      def remove(_arg, _path, _recursive), do: {:error, :enotsup}
      def list(_arg, _path), do: {:error, :enotsup}

      # Derive file metadata from read/2 so a read-only backend needs only read/2.
      # `with` (no `else`) passes a non-`{:ok, _}` read result straight through,
      # and gives the type checker no dead clause to flag when read/2 is total.
      def stat(arg, path) do
        with {:ok, content} <- read(arg, path) do
          {:ok, %{type: :file, size: IO.iodata_length(content)}}
        end
      end

      defoverridable read: 2, write: 3, append: 3, mkdir: 3, remove: 3, list: 2, stat: 2
    end
  end
end
