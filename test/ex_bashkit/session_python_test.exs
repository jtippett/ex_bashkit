# The `python` builtin is only available when the optional `:ex_monty` dependency
# is present. Define the suite only then, so the project still tests cleanly
# without it.
if Code.ensure_loaded?(ExMonty) do
  defmodule ExBashkit.SessionPythonTest do
    use ExUnit.Case, async: true

    alias ExBashkit.{Result, Session}

    describe "source forms" do
      test "python -c runs inline code and captures stdout" do
        s = Session.new(python: true)

        assert {:ok, %Result{stdout: "2\n", exit_code: 0}} =
                 Session.exec(s, "python -c 'print(1 + 1)'")
      end

      test "a script piped on stdin runs" do
        s = Session.new(python: true)

        assert {:ok, %Result{stdout: "hi\n", exit_code: 0}} =
                 Session.exec(s, "echo 'print(\"hi\")' | python")
      end

      test "python3 is registered too" do
        s = Session.new(python: true)
        assert {:ok, %Result{stdout: "3\n"}} = Session.exec(s, "python3 -c 'print(3)'")
      end

      test "a script file is read from the session filesystem" do
        s = Session.new(python: true)
        assert {:ok, _} = Session.exec(s, "echo 'print(40 + 2)' > /prog.py")
        assert {:ok, %Result{stdout: "42\n", exit_code: 0}} = Session.exec(s, "python /prog.py")
      end

      test "a relative script path resolves against the working directory" do
        s = Session.new(python: true)
        assert {:ok, _} = Session.exec(s, "mkdir /work; echo 'print(7)' > /work/p.py")
        assert {:ok, %Result{stdout: "7\n"}} = Session.exec(s, "cd /work; python p.py")
      end
    end

    describe "shared filesystem" do
      test "Python reads a file a bash step wrote" do
        s = Session.new(python: true)
        assert {:ok, _} = Session.exec(s, "echo hello > /data.txt")

        code = "from pathlib import Path; print(Path('/data.txt').read_text().strip())"

        assert {:ok, %Result{stdout: "hello\n", exit_code: 0}} =
                 Session.exec(s, "python -c \"#{code}\"")
      end

      test "a bash step reads a file Python wrote" do
        s = Session.new(python: true)
        code = "from pathlib import Path; Path('/out.txt').write_text('from python\\n')"
        assert {:ok, %Result{exit_code: 0}} = Session.exec(s, "python -c \"#{code}\"")
        assert {:ok, %Result{stdout: "from python\n"}} = Session.exec(s, "cat /out.txt")
      end

      test "a curl|python|bash style pipeline shares files end to end" do
        s = Session.new(python: true)
        assert {:ok, _} = Session.exec(s, "printf '1\\n2\\n3\\n' > /nums.txt")

        prog = """
        from pathlib import Path
        nums = [int(x) for x in Path('/nums.txt').read_text().split()]
        Path('/sum.txt').write_text(str(sum(nums)))
        """

        assert {:ok, _} = Session.exec(s, "cat > /sum.py <<'EOF'\n#{prog}EOF")
        assert {:ok, %Result{exit_code: 0}} = Session.exec(s, "python /sum.py")
        assert {:ok, %Result{stdout: "6\n"}} = Session.exec(s, "cat /sum.txt; echo")
      end

      test "exists/stat reflect the shared filesystem" do
        s = Session.new(python: true)
        assert {:ok, _} = Session.exec(s, "printf 12345 > /f")

        code =
          "from pathlib import Path; p = Path('/f'); print(p.exists(), p.stat().st_size, Path('/no').exists())"

        assert {:ok, %Result{stdout: out, exit_code: 0}} =
                 Session.exec(s, "python -c \"#{code}\"")

        assert out =~ "True 5 False"
      end

      test "Path.mkdir is visible to bash" do
        s = Session.new(python: true)

        code = "from pathlib import Path; Path('/made/deep').mkdir(parents=True)"
        assert {:ok, %Result{exit_code: 0}} = Session.exec(s, "python -c \"#{code}\"")
        assert {:ok, %{type: :dir}} = Session.stat(s, "/made/deep")
      end

      test "mkdir(parents=True) on an existing dir still raises FileExistsError" do
        s = Session.new(python: true)
        assert {:ok, _} = Session.exec(s, "mkdir /there")

        code = "from pathlib import Path; Path('/there').mkdir(parents=True)"

        assert {:ok, %Result{exit_code: c, stderr: err}} =
                 Session.exec(s, "python -c \"#{code}\"")

        assert c != 0
        assert err =~ "Error" or err =~ "exists"
      end

      test "writing to a missing parent path creates the parents (like write_file)" do
        s = Session.new(python: true)
        code = "from pathlib import Path; Path('/deep/nest/f.txt').write_text('ok')"
        assert {:ok, %Result{exit_code: 0}} = Session.exec(s, "python -c \"#{code}\"")
        assert {:ok, "ok"} = Session.read_file(s, "/deep/nest/f.txt")
      end

      test "iterdir, unlink and rename round-trip against the shared filesystem" do
        s = Session.new(python: true)
        assert {:ok, _} = Session.exec(s, "mkdir /dir; echo a > /dir/a; echo b > /dir/b")

        list = "from pathlib import Path; print(sorted(p.name for p in Path('/dir').iterdir()))"
        assert {:ok, %Result{stdout: out}} = Session.exec(s, "python -c \"#{list}\"")
        assert out =~ "['a', 'b']"

        ops = "from pathlib import Path; Path('/dir/a').rename('/dir/c'); Path('/dir/b').unlink()"
        assert {:ok, %Result{exit_code: 0}} = Session.exec(s, "python -c \"#{ops}\"")
        assert {:ok, %{type: :file}} = Session.stat(s, "/dir/c")
        assert {:error, _} = Session.stat(s, "/dir/a")
        assert {:error, _} = Session.stat(s, "/dir/b")
      end

      test "read_bytes/write_bytes round-trip binary content" do
        s = Session.new(python: true)

        code =
          "from pathlib import Path; Path('/b.bin').write_bytes(b'\\\\x00\\\\x01\\\\xff'); print(len(Path('/b.bin').read_bytes()))"

        assert {:ok, %Result{stdout: "3\n", exit_code: 0}} =
                 Session.exec(s, "python -c \"#{code}\"")

        assert {:ok, <<0, 1, 255>>} = Session.read_file(s, "/b.bin")
      end

      test "os.getenv reads the session environment" do
        s = Session.new(python: true, env: %{"TOKEN" => "sek"})
        code = "import os; print(os.getenv('TOKEN'), os.getenv('NOPE', 'def'))"

        assert {:ok, %Result{stdout: out, exit_code: 0}} =
                 Session.exec(s, "TOKEN=sek python -c \"#{code}\"")

        assert out =~ "sek def"
      end

      test "python can read an Elixir-backed :virtual_fs mount (nested back-call)" do
        # The python builtin and the virtual_fs backend both ride the same handler
        # process; reading the mount from inside python is a nested back-call. The
        # handler must stay free to service it (else it deadlocks/times out).
        s =
          Session.new(
            python: true,
            virtual_fs: %{"/api" => fn %{op: :read, path: "/" <> k} -> {:ok, "v:#{k}\n"} end}
          )

        code = "from pathlib import Path; print(Path('/api/widget').read_text().strip())"

        assert {:ok, %Result{stdout: "v:widget\n", exit_code: 0}} =
                 Session.exec(s, "python3 -c \"#{code}\"")
      end

      test "python can write through a :virtual_fs mount" do
        {:ok, store} = Agent.start_link(fn -> %{} end)

        backend = fn
          %{op: :write, path: "/" <> k, data: d} ->
            Agent.update(store, &Map.put(&1, k, d))
            :ok

          %{op: :read, path: "/" <> k} ->
            case Agent.get(store, &Map.get(&1, k)) do
              nil -> {:error, :enoent}
              v -> {:ok, v}
            end

          # write_file/3 creates the parent (mkdir -p) before writing, which for a
          # write at the mount root is a mkdir on "/". A writable backend handles it.
          %{op: :mkdir} ->
            :ok

          _ ->
            {:error, :enotsup}
        end

        s = Session.new(python: true, virtual_fs: %{"/kv" => backend})
        code = "from pathlib import Path; Path('/kv/x').write_text('from-python')"
        assert {:ok, %Result{exit_code: 0}} = Session.exec(s, "python3 -c \"#{code}\"")
        assert Agent.get(store, &Map.get(&1, "x")) == "from-python"
      end
    end

    describe "errors and isolation" do
      test "reading a missing file raises FileNotFoundError and fails the command, not the session" do
        s = Session.new(python: true)

        code = "from pathlib import Path; print(Path('/nope').read_text())"

        assert {:ok, %Result{exit_code: code_exit, stderr: err}} =
                 Session.exec(s, "python -c \"#{code}\"")

        assert code_exit != 0
        assert err =~ "FileNotFound" or err =~ "No such file" or err =~ "not found"

        assert {:ok, %Result{stdout: "ok\n"}} = Session.exec(s, "echo ok")
      end

      test "a Python exception fails the command but leaves the session usable" do
        s = Session.new(python: true)
        assert {:ok, %Result{exit_code: c}} = Session.exec(s, "python -c '1/0'")
        assert c != 0
        assert {:ok, %Result{stdout: "still here\n"}} = Session.exec(s, "echo 'still here'")
      end

      test "an infinite loop is bounded and does not wedge the session" do
        s = Session.new(python: true, builtin_timeout_ms: 1_000)
        assert {:ok, %Result{exit_code: c}} = Session.exec(s, "python -c 'while True: pass'")
        assert c != 0
        assert {:ok, %Result{stdout: "alive\n"}} = Session.exec(s, "echo alive")
      end

      test "an effect outside the filesystem (e.g. the clock) is denied, not granted" do
        s = Session.new(python: true)
        code = "from datetime import datetime; print(datetime.now())"
        assert {:ok, %Result{exit_code: c}} = Session.exec(s, "python -c \"#{code}\"")
        assert c != 0
        assert {:ok, %Result{stdout: "ok\n"}} = Session.exec(s, "echo ok")
      end
    end

    describe "opt-in / composition" do
      test "without python: the command is unavailable" do
        s = Session.new()
        assert {:ok, %Result{exit_code: c}} = Session.exec(s, "python -c 'print(1)'")
        assert c != 0
      end

      test "python coexists with custom builtins and virtual_fs" do
        s =
          Session.new(
            python: true,
            builtins: %{"hi" => fn _ -> {:ok, "hi\n"} end},
            virtual_fs: %{"/api" => fn %{op: :read, path: "/" <> k} -> {:ok, "v:#{k}\n"} end}
          )

        assert {:ok, %Result{stdout: "hi\n"}} = Session.exec(s, "hi")
        assert {:ok, %Result{stdout: "v:x\n"}} = Session.exec(s, "cat /api/x")
        assert {:ok, %Result{stdout: "9\n"}} = Session.exec(s, "python -c 'print(9)'")
      end

      test "a custom builtin name colliding with a python name raises" do
        assert_raise ArgumentError, ~r/python/, fn ->
          Session.new(python: true, builtins: %{"python" => fn _ -> {:ok, ""} end})
        end
      end
    end
  end
end
