defmodule ExBashkit.SessionVfsDynamicTest do
  use ExUnit.Case, async: true

  alias ExBashkit.{Result, Session}

  # --- a behaviour-module backend over an Agent-held map ---------------------

  defmodule KvFs do
    use ExBashkit.VirtualFs

    @impl true
    def read(kv, "/" <> key) do
      case Agent.get(kv, &Map.get(&1, key)) do
        nil -> {:error, :enoent}
        value -> {:ok, value}
      end
    end

    @impl true
    def write(kv, "/" <> key, data) do
      Agent.update(kv, &Map.put(&1, key, data))
      :ok
    end

    @impl true
    def list(kv, "/"), do: {:ok, Agent.get(kv, &Map.keys(&1))}

    # stat is *not* implemented — the `use` default derives it from read/2.
    # remove is *not* implemented — defaults to {:error, :enotsup}.
  end

  defmodule StaticFs do
    use ExBashkit.VirtualFs

    @impl true
    def read(_arg, "/" <> name), do: {:ok, "static:#{name}\n"}
  end

  defp start_kv(initial) do
    {:ok, pid} = Agent.start_link(fn -> initial end)
    pid
  end

  # A map-backed dynamic FS as a single dispatch function.
  defp kv_fun(kv) do
    fn
      %{op: :read, path: "/" <> key} ->
        case Agent.get(kv, &Map.get(&1, key)) do
          nil -> {:error, :enoent}
          value -> {:ok, value}
        end

      %{op: :write, path: "/" <> key, data: data} ->
        Agent.update(kv, &Map.put(&1, key, data))
        :ok

      %{op: :list, path: "/"} ->
        {:ok, Agent.get(kv, &Map.keys(&1))}

      %{op: :stat, path: "/" <> key} ->
        case Agent.get(kv, &Map.get(&1, key)) do
          nil -> {:error, :enoent}
          value -> {:ok, %{type: :file, size: byte_size(value)}}
        end

      %{op: :remove, path: "/" <> key} ->
        Agent.update(kv, &Map.delete(&1, key))
        :ok

      _ ->
        {:error, :enotsup}
    end
  end

  describe "function form" do
    setup do
      kv = start_kv(%{"greeting" => "hello\n"})
      session = Session.new(virtual_fs: %{"/kv" => kv_fun(kv)})
      %{session: session, kv: kv}
    end

    test "reads a generated file", %{session: s} do
      assert {:ok, %Result{stdout: "hello\n", exit_code: 0}} = Session.exec(s, "cat /kv/greeting")
    end

    test "a missing file is reported as not found", %{session: s} do
      assert {:ok, %Result{exit_code: code, stderr: err}} = Session.exec(s, "cat /kv/nope")
      assert code != 0
      assert err =~ "No such file"
    end

    test "writes back through the mount", %{session: s, kv: kv} do
      assert {:ok, %Result{exit_code: 0}} = Session.exec(s, "echo written > /kv/foo")
      assert Agent.get(kv, &Map.get(&1, "foo")) == "written\n"
    end

    test "lists the directory", %{session: s} do
      assert {:ok, %Result{stdout: out, exit_code: 0}} = Session.exec(s, "ls /kv")
      assert out =~ "greeting"
    end

    test "removes a file", %{session: s, kv: kv} do
      assert {:ok, %Result{exit_code: 0}} = Session.exec(s, "rm /kv/greeting")
      assert Agent.get(kv, &Map.get(&1, "greeting")) == nil
    end

    test "test -f reflects existence (exists derived from stat)", %{session: s} do
      assert {:ok, %Result{exit_code: 0}} = Session.exec(s, "test -f /kv/greeting")
      assert {:ok, %Result{exit_code: 1}} = Session.exec(s, "test -f /kv/nope")
    end
  end

  describe "behaviour form" do
    test "reads via a {module, arg} backend" do
      kv = start_kv(%{"a" => "A\n"})
      session = Session.new(virtual_fs: %{"/m" => {KvFs, kv}})
      assert {:ok, %Result{stdout: "A\n"}} = Session.exec(session, "cat /m/a")
    end

    test "implementing only read/2 still gives a working test -f (derived stat)" do
      kv = start_kv(%{"a" => "A\n"})
      session = Session.new(virtual_fs: %{"/m" => {KvFs, kv}})
      assert {:ok, %Result{exit_code: 0}} = Session.exec(session, "test -f /m/a")
      assert {:ok, %Result{exit_code: 1}} = Session.exec(session, "test -f /m/missing")
    end

    test "an unimplemented op defaults to a not-supported error" do
      kv = start_kv(%{"a" => "A\n"})
      session = Session.new(virtual_fs: %{"/m" => {KvFs, kv}})
      assert {:ok, %Result{exit_code: code}} = Session.exec(session, "rm /m/a")
      assert code != 0
    end

    test "a bare module gets a nil arg" do
      session = Session.new(virtual_fs: %{"/s" => StaticFs})
      assert {:ok, %Result{stdout: "static:x\n"}} = Session.exec(session, "cat /s/x")
    end
  end

  describe "composition" do
    test "a virtual mount coexists with :files, :builtins, and the in-memory FS" do
      session =
        Session.new(
          files: %{"/seed.txt" => "seeded\n"},
          builtins: %{"hi" => fn _ -> {:ok, "hi\n"} end},
          virtual_fs: %{"/api" => fn %{op: :read, path: "/" <> k} -> {:ok, "v:#{k}\n"} end}
        )

      assert {:ok, %Result{stdout: "seeded\n"}} = Session.exec(session, "cat /seed.txt")
      assert {:ok, %Result{stdout: "hi\n"}} = Session.exec(session, "hi")
      assert {:ok, %Result{stdout: "v:thing\n"}} = Session.exec(session, "cat /api/thing")

      assert {:ok, %Result{stdout: "x\n", exit_code: 0}} =
               Session.exec(session, "echo x > /tmp/y; cat /tmp/y")
    end
  end

  describe "write paths" do
    test "append (>>) and mkdir reach the backend with the right shape" do
      {:ok, recorder} = Agent.start_link(fn -> [] end)

      record = fn op, extra ->
        Agent.update(recorder, &[{op, extra} | &1])
      end

      backend = fn
        %{op: :append, path: path, data: data} -> record.(:append, {path, data})
        %{op: :mkdir, path: path, recursive: recursive} -> record.(:mkdir, {path, recursive})
        %{op: :read, path: _} -> {:ok, ""}
        _ -> {:error, :enotsup}
      end

      session = Session.new(virtual_fs: %{"/rec" => backend})

      assert {:ok, %Result{exit_code: 0}} = Session.exec(session, "printf x >> /rec/file")
      assert {:ok, %Result{exit_code: 0}} = Session.exec(session, "mkdir -p /rec/a/b")

      ops = Agent.get(recorder, &Enum.reverse/1)
      assert {:append, {"/file", "x"}} in ops
      assert {:mkdir, {"/a/b", true}} in ops
    end

    test "writing to a backend that only implements read/2 fails (enotsup default)" do
      # StaticFs implements only read/2; write defaults to {:error, :enotsup}.
      session = Session.new(virtual_fs: %{"/s" => StaticFs})
      assert {:ok, %Result{exit_code: code}} = Session.exec(session, "echo hi > /s/file")
      assert code != 0
    end
  end

  describe "failure isolation" do
    test "a raising handler fails the op but leaves the session usable" do
      session =
        Session.new(virtual_fs: %{"/api" => fn _ -> raise "boom" end})

      assert {:ok, %Result{exit_code: code}} = Session.exec(session, "cat /api/x")
      assert code != 0

      assert {:ok, %Result{stdout: "ok\n"}} = Session.exec(session, "echo ok")
    end

    test "a backend slower than :builtin_timeout_ms fails the op (session stays usable)" do
      slow =
        fn _ ->
          Process.sleep(300)
          {:ok, "late\n"}
        end

      session = Session.new(virtual_fs: %{"/slow" => slow}, builtin_timeout_ms: 50)

      assert {:ok, %Result{exit_code: code}} = Session.exec(session, "cat /slow/x")
      assert code != 0

      assert {:ok, %Result{stdout: "ok\n"}} = Session.exec(session, "echo ok")
    end

    test "a slow backend doesn't block a later back-call in the same exec" do
      # The FS op runs in a brutal-killed child, so the handler loop stays free:
      # a builtin invoked *after* a timed-out slow read is still serviced within
      # the same script. (When the FS op ran synchronously in the loop, this
      # builtin queued behind the 2s sleep and timed out too.)
      slow_read =
        fn
          %{op: :read} ->
            Process.sleep(2_000)
            {:ok, "slow\n"}

          %{op: :stat} ->
            {:ok, %{type: :file, size: 5}}

          _ ->
            {:error, :enotsup}
        end

      session =
        Session.new(
          builtin_timeout_ms: 200,
          builtins: %{"after_slow" => fn _ -> {:ok, "ran\n"} end},
          virtual_fs: %{"/slow" => slow_read}
        )

      assert {:ok, %Result{stdout: stdout}} = Session.exec(session, "cat /slow/x; after_slow")
      assert stdout =~ "ran"
    end

    test "a backend cancelled by the script timeout doesn't wedge the session" do
      # bashkit's own execution timeout fires while the FS back-call is parked,
      # dropping the exec future; PendingFsCleanup must free the slot and the
      # session must stay usable. :builtin_timeout_ms is large so the script
      # timeout wins.
      slow =
        fn _ ->
          Process.sleep(400)
          {:ok, "late\n"}
        end

      session =
        Session.new(
          virtual_fs: %{"/slow" => slow},
          limits: [timeout_ms: 50],
          builtin_timeout_ms: 5_000
        )

      assert {:error, message} = Session.exec(session, "cat /slow/x")
      assert is_binary(message)

      assert {:ok, %Result{stdout: "ok\n"}} = Session.exec(session, "echo ok")
    end
  end

  describe "concurrency" do
    test "virtual filesystems stay isolated across concurrent sessions" do
      make = fn tag ->
        Session.new(
          virtual_fs: %{"/m" => fn %{op: :read, path: "/" <> k} -> {:ok, "#{tag}:#{k}\n"} end}
        )
      end

      a = make.("A")
      b = make.("B")

      run = fn session -> for i <- 1..25, do: Session.exec(session, "cat /m/#{i}") end

      [ra, rb] =
        [Task.async(fn -> run.(a) end), Task.async(fn -> run.(b) end)] |> Task.await_many()

      assert Enum.all?(ra, &match?({:ok, %Result{stdout: "A:" <> _}}, &1))
      assert Enum.all?(rb, &match?({:ok, %Result{stdout: "B:" <> _}}, &1))
      assert {:ok, %Result{stdout: "A:25\n"}} = List.last(ra)
      assert {:ok, %Result{stdout: "B:25\n"}} = List.last(rb)
    end
  end

  describe "validation" do
    test "a spec that is not a fun/module/{module, arg} raises" do
      assert_raise ArgumentError, ~r/virtual_fs/, fn ->
        Session.new(virtual_fs: %{"/api" => 123})
      end
    end

    test "a non-absolute mount path raises" do
      assert_raise ArgumentError, fn ->
        Session.new(virtual_fs: %{"rel" => fn _ -> {:ok, ""} end})
      end
    end
  end
end
