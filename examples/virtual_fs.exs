# Run with:  mix run examples/virtual_fs.exs
#
# Virtual filesystem backends: mount an Elixir-backed filesystem so a script's
# reads and writes are serviced by your application. Here a `/kv` mount is backed
# by an in-memory key/value store (an Agent) via the ExBashkit.VirtualFs
# behaviour — `cat`, `echo >`, `ls`, and `rm` all round-trip through Elixir.

alias ExBashkit.{Result, Session}

defmodule KvStore do
  use Agent

  def start_link(initial), do: Agent.start_link(fn -> initial end)
  def get(pid, key), do: Agent.get(pid, &Map.get(&1, key))
  def put(pid, key, value), do: Agent.update(pid, &Map.put(&1, key, value))
  def delete(pid, key), do: Agent.update(pid, &Map.delete(&1, key))
  def keys(pid), do: Agent.get(pid, &Map.keys(&1))
end

defmodule KvFs do
  use ExBashkit.VirtualFs

  @impl true
  def read(kv, "/" <> key) do
    case KvStore.get(kv, key) do
      nil -> {:error, :enoent}
      value -> {:ok, value}
    end
  end

  @impl true
  def write(kv, "/" <> key, data) do
    KvStore.put(kv, key, data)
    :ok
  end

  @impl true
  def remove(kv, "/" <> key, _recursive) do
    KvStore.delete(kv, key)
    :ok
  end

  @impl true
  def list(kv, "/"), do: {:ok, KvStore.keys(kv)}

  # stat is derived from read/2 by `use ExBashkit.VirtualFs`.
end

defmodule Demo do
  def show(session, label, script) do
    case Session.exec(session, script) do
      {:ok, %Result{stdout: out, stderr: err, exit_code: code}} ->
        IO.puts("\n# #{label}  (exit #{code})")
        if out != "", do: IO.write(out)
        if err != "", do: IO.write([IO.ANSI.yellow(), err, IO.ANSI.reset()])

      {:error, message} ->
        IO.puts("\n# #{label}  (error)")
        IO.puts([IO.ANSI.red(), message, IO.ANSI.reset()])
    end
  end
end

# A second backend in the *function* form: a read-only generator. Nothing is
# stored — content is computed on read. Only :read is needed; `cat` works because
# the behaviour's derived stat reports it as a file.
calc =
  fn
    %{op: :read, path: "/double/" <> n} -> {:ok, "#{String.to_integer(n) * 2}\n"}
    %{op: :read, path: "/upper/" <> s} -> {:ok, String.upcase(s) <> "\n"}
    %{op: :read, path: _} -> {:error, :enoent}
    _ -> {:error, :enotsup}
  end

{:ok, kv} = KvStore.start_link(%{"greeting" => "hello\n"})

# One session, two Elixir-backed mounts (and they compose with everything else).
session = Session.new(virtual_fs: %{"/kv" => {KvFs, kv}, "/calc" => calc})

# --- the function-form, read-only generator ---
Demo.show(session, "compute (fn form)", "echo \"2 x 21 = $(cat /calc/double/21)\"")

# --- the behaviour-module, read-write store ---

# Read a "file" that is really a store entry.
Demo.show(session, "read", "cat /kv/greeting")

# Write back through the mount; the store is updated.
Demo.show(session, "write", "echo 'see ya' > /kv/farewell")
IO.puts("   (store now has: #{inspect(KvStore.keys(kv))})")

# List the directory.
Demo.show(session, "list", "ls /kv")

# A missing key is a normal 'no such file'.
Demo.show(session, "missing", "cat /kv/nope")

# Remove an entry.
Demo.show(session, "remove", "rm /kv/greeting && echo removed")
IO.puts("   (store now has: #{inspect(KvStore.keys(kv))})")
