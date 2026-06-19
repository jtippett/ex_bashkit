defmodule ExBashkit.SessionSnapshotTest do
  use ExUnit.Case, async: true

  alias ExBashkit.{Result, Session}

  # A snapshot carries shell state + in-memory VFS contents. It does NOT carry
  # session *config* (builtins, virtual_fs, mounts, limits, env) — to resume you
  # rebuild a session with the same capabilities, then restore state into it.

  describe "round-trip" do
    test "a shell variable survives snapshot -> rebuild -> restore" do
      a = Session.new()
      assert {:ok, %Result{exit_code: 0}} = Session.exec(a, "x=42")

      {:ok, bytes} = Session.snapshot(a)
      assert is_binary(bytes)

      b = Session.new()
      # Before restore, the fresh session knows nothing.
      assert {:ok, %Result{stdout: "\n"}} = Session.exec(b, "echo $x")

      assert {:ok, %Session{} = b} = Session.restore(b, bytes)
      assert {:ok, %Result{stdout: "42\n"}} = Session.exec(b, "echo $x")
    end

    test "in-memory filesystem contents survive the round-trip" do
      a = Session.new()
      assert {:ok, %Result{exit_code: 0}} = Session.exec(a, "echo hi > /a.txt")

      {:ok, bytes} = Session.snapshot(a)

      b = Session.new()
      {:ok, b} = Session.restore(b, bytes)
      assert {:ok, %Result{stdout: "hi\n"}} = Session.exec(b, "cat /a.txt")
    end

    test "a shell function survives by default" do
      a = Session.new()
      assert {:ok, %Result{exit_code: 0}} = Session.exec(a, "greet() { echo hello; }")

      {:ok, bytes} = Session.snapshot(a)

      b = Session.new()
      {:ok, b} = Session.restore(b, bytes)
      assert {:ok, %Result{stdout: "hello\n"}} = Session.exec(b, "greet")
    end

    test "restoring into the same session reverts later mutations" do
      s = Session.new()
      assert {:ok, %Result{exit_code: 0}} = Session.exec(s, "x=1")
      {:ok, bytes} = Session.snapshot(s)

      assert {:ok, %Result{exit_code: 0}} = Session.exec(s, "x=2")
      assert {:ok, %Result{stdout: "2\n"}} = Session.exec(s, "echo $x")

      {:ok, s} = Session.restore(s, bytes)
      assert {:ok, %Result{stdout: "1\n"}} = Session.exec(s, "echo $x")
    end
  end

  describe "options" do
    test ":exclude_filesystem keeps shell state but drops VFS contents" do
      a = Session.new()
      assert {:ok, %Result{exit_code: 0}} = Session.exec(a, "x=7; echo data > /f.txt")

      {:ok, bytes} = Session.snapshot(a, exclude_filesystem: true)

      b = Session.new()
      {:ok, b} = Session.restore(b, bytes)
      assert {:ok, %Result{stdout: "7\n"}} = Session.exec(b, "echo $x")
      assert {:ok, %Result{exit_code: code}} = Session.exec(b, "cat /f.txt")
      assert code != 0
    end

    test ":exclude_functions keeps shell vars but drops functions" do
      a = Session.new()
      assert {:ok, %Result{exit_code: 0}} = Session.exec(a, "x=7; greet() { echo hi; }")

      {:ok, bytes} = Session.snapshot(a, exclude_functions: true)

      b = Session.new()
      {:ok, b} = Session.restore(b, bytes)
      assert {:ok, %Result{stdout: "7\n"}} = Session.exec(b, "echo $x")
      assert {:ok, %Result{exit_code: code}} = Session.exec(b, "greet")
      assert code != 0
    end
  end

  describe "option validation" do
    test "a non-binary key is rejected" do
      s = Session.new()
      assert_raise ArgumentError, ~r/:key/, fn -> Session.snapshot(s, key: :secret) end
      assert_raise ArgumentError, ~r/:key/, fn -> Session.restore(s, <<>>, key: 123) end
    end

    test "an empty key is rejected (not a secret)" do
      s = Session.new()
      assert_raise ArgumentError, ~r/empty/, fn -> Session.snapshot(s, key: "") end
      assert_raise ArgumentError, ~r/empty/, fn -> Session.restore(s, <<>>, key: "") end
    end

    test "non-boolean exclude flags are rejected" do
      s = Session.new()

      assert_raise ArgumentError, ~r/exclude_filesystem/, fn ->
        Session.snapshot(s, exclude_filesystem: :yes)
      end

      assert_raise ArgumentError, ~r/exclude_functions/, fn ->
        Session.snapshot(s, exclude_functions: 1)
      end
    end

    test "both exclude flags together capture shell-only, function-free state" do
      a = Session.new()

      assert {:ok, %Result{exit_code: 0}} =
               Session.exec(a, "x=5; greet() { echo hi; }; echo d > /f")

      {:ok, bytes} = Session.snapshot(a, exclude_filesystem: true, exclude_functions: true)

      b = Session.new()
      {:ok, b} = Session.restore(b, bytes)
      assert {:ok, %Result{stdout: "5\n"}} = Session.exec(b, "echo $x")
      assert {:ok, %Result{exit_code: fc}} = Session.exec(b, "greet")
      assert fc != 0
      assert {:ok, %Result{exit_code: cc}} = Session.exec(b, "cat /f")
      assert cc != 0
    end
  end

  describe "snapshot boundary" do
    test "a :virtual_fs mount's contents are not captured (only the in-memory FS travels)" do
      # The mount is backed live by Elixir; its content lives outside bashkit, so
      # the snapshot must not carry it. A restore into a session WITHOUT the mount
      # therefore cannot read those paths, while in-memory FS content does survive.
      a =
        Session.new(
          virtual_fs: %{"/api" => fn %{op: :read, path: "/" <> k} -> {:ok, "v:#{k}\n"} end}
        )

      assert {:ok, %Result{stdout: "v:x\n"}} = Session.exec(a, "cat /api/x")
      assert {:ok, %Result{exit_code: 0}} = Session.exec(a, "echo mem > /mem.txt")

      {:ok, bytes} = Session.snapshot(a)

      b = Session.new()
      {:ok, b} = Session.restore(b, bytes)
      # In-memory FS content survived...
      assert {:ok, %Result{stdout: "mem\n"}} = Session.exec(b, "cat /mem.txt")
      # ...but the virtual mount did not (no /api backend on b).
      assert {:ok, %Result{exit_code: code}} = Session.exec(b, "cat /api/x")
      assert code != 0
    end
  end

  describe "keyed (trust-boundary) snapshots" do
    test "round-trips when the key matches" do
      key = "s3cr3t-key"
      a = Session.new()
      assert {:ok, %Result{exit_code: 0}} = Session.exec(a, "token=abc123")

      {:ok, bytes} = Session.snapshot(a, key: key)

      b = Session.new()
      assert {:ok, b} = Session.restore(b, bytes, key: key)
      assert {:ok, %Result{stdout: "abc123\n"}} = Session.exec(b, "echo $token")
    end

    test "a wrong key is rejected and the session stays usable" do
      a = Session.new()
      assert {:ok, %Result{exit_code: 0}} = Session.exec(a, "token=abc123")
      {:ok, bytes} = Session.snapshot(a, key: "right-key")

      b = Session.new()
      assert {:error, message} = Session.restore(b, bytes, key: "wrong-key")
      assert is_binary(message)

      assert {:ok, %Result{stdout: "ok\n"}} = Session.exec(b, "echo ok")
    end

    test "keyed bytes cannot be restored without a key" do
      a = Session.new()
      assert {:ok, %Result{exit_code: 0}} = Session.exec(a, "token=abc123")
      {:ok, bytes} = Session.snapshot(a, key: "right-key")

      b = Session.new()
      assert {:error, _} = Session.restore(b, bytes)
    end

    test "plain bytes cannot be restored with a key" do
      a = Session.new()
      assert {:ok, %Result{exit_code: 0}} = Session.exec(a, "token=abc123")
      {:ok, bytes} = Session.snapshot(a)

      b = Session.new()
      assert {:error, _} = Session.restore(b, bytes, key: "some-key")
    end
  end

  describe "corruption" do
    test "tampered bytes are rejected" do
      a = Session.new()
      assert {:ok, %Result{exit_code: 0}} = Session.exec(a, "x=1")
      {:ok, bytes} = Session.snapshot(a)

      <<first, rest::binary>> = bytes
      tampered = <<Bitwise.bxor(first, 0xFF), rest::binary>>

      b = Session.new()
      assert {:error, message} = Session.restore(b, tampered)
      assert is_binary(message)
      assert {:ok, %Result{stdout: "ok\n"}} = Session.exec(b, "echo ok")
    end

    test "garbage bytes are rejected, not crashing the caller" do
      b = Session.new()
      assert {:error, _} = Session.restore(b, "not a snapshot")
      assert {:error, _} = Session.restore(b, <<>>)
      assert {:ok, %Result{stdout: "ok\n"}} = Session.exec(b, "echo ok")
    end
  end

  describe "capability preservation" do
    test "restore preserves the target session's own builtins and mounts" do
      # Snapshot from a plain session that only set a variable.
      a = Session.new()
      assert {:ok, %Result{exit_code: 0}} = Session.exec(a, "x=99")
      {:ok, bytes} = Session.snapshot(a)

      # Restore into a session configured with a custom builtin and a virtual_fs
      # mount. Those capabilities are NOT in the bytes; they must survive restore.
      b =
        Session.new(
          builtins: %{"hi" => fn _ -> {:ok, "hi\n"} end},
          virtual_fs: %{"/api" => fn %{op: :read, path: "/" <> k} -> {:ok, "v:#{k}\n"} end}
        )

      {:ok, b} = Session.restore(b, bytes)

      # Loaded shell state from the snapshot:
      assert {:ok, %Result{stdout: "99\n"}} = Session.exec(b, "echo $x")
      # Preserved live capabilities on the target:
      assert {:ok, %Result{stdout: "hi\n"}} = Session.exec(b, "hi")
      assert {:ok, %Result{stdout: "v:thing\n"}} = Session.exec(b, "cat /api/thing")
    end
  end
end
