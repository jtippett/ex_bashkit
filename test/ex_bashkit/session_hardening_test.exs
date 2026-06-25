defmodule ExBashkit.SessionHardeningTest do
  # Not async: these toggle Application env (global) for the hardening knobs.
  use ExUnit.Case, async: false

  alias ExBashkit.{Result, Session}

  describe ":max_reply_bytes cap on builtin replies" do
    setup do
      # Tiny cap so we don't have to allocate megabytes to cross it.
      Application.put_env(:ex_bashkit, :max_reply_bytes, 16)
      on_exit(fn -> Application.delete_env(:ex_bashkit, :max_reply_bytes) end)
    end

    test "an over-cap {:ok, _} reply fails that command instead of crossing the bridge" do
      session = Session.new(builtins: %{"big" => fn _ -> {:ok, String.duplicate("A", 1_000)} end})

      assert {:ok, %Result{stdout: "", exit_code: 1, stderr: stderr}} =
               Session.exec(session, "big")

      assert stderr =~ "exceeds the 16-byte reply limit"
    end

    test "an over-cap %Result{} stderr is also rejected" do
      session =
        Session.new(
          builtins: %{"big" => fn _ -> %Result{stderr: String.duplicate("e", 1_000)} end}
        )

      assert {:ok, %Result{exit_code: 1, stderr: stderr}} = Session.exec(session, "big")
      assert stderr =~ "exceeds the 16-byte reply limit"
    end

    test "a reply at or under the cap passes through untouched" do
      session = Session.new(builtins: %{"ok" => fn _ -> {:ok, "0123456789"} end})

      assert {:ok, %Result{stdout: "0123456789", exit_code: 0}} = Session.exec(session, "ok")
    end

    test "an over-cap virtual_fs read fails that op, not the session" do
      session =
        Session.new(
          virtual_fs: %{
            "/v" => fn %{op: :read} -> {:ok, String.duplicate("A", 1_000)} end
          }
        )

      assert {:ok, %Result{exit_code: code}} = Session.exec(session, "cat /v/big")
      assert code != 0
      # The session is still usable afterwards.
      assert {:ok, %Result{stdout: "hi\n"}} = Session.exec(session, "echo hi")
    end

    test "an over-cap virtual_fs directory listing fails that op" do
      names = for i <- 1..100, do: "file#{i}"

      session =
        Session.new(
          virtual_fs: %{
            "/v" => fn
              %{op: :list} -> {:ok, names}
              %{op: :stat} -> {:ok, %{type: :dir, size: 0}}
            end
          }
        )

      assert {:ok, %Result{exit_code: code}} = Session.exec(session, "ls /v")
      assert code != 0
    end
  end

  describe ":max_timeout_ms ceiling" do
    setup do
      Application.put_env(:ex_bashkit, :max_timeout_ms, 5_000)
      on_exit(fn -> Application.delete_env(:ex_bashkit, :max_timeout_ms) end)
    end

    test "a session whose :timeout_ms exceeds the ceiling raises" do
      assert_raise ArgumentError,
                   ~r/exceeds the configured :max_timeout_ms ceiling of 5000/,
                   fn ->
                     Session.new(limits: [timeout_ms: 60_000])
                   end
    end

    test "a :timeout_ms at or under the ceiling is accepted" do
      session = Session.new(limits: [timeout_ms: 5_000])
      assert {:ok, %Result{}} = Session.exec(session, "echo hi")
    end

    test "a session that sets no :timeout_ms is unaffected by the ceiling" do
      session = Session.new()
      assert {:ok, %Result{stdout: "hi\n"}} = Session.exec(session, "echo hi")
    end

    test "a malformed ceiling config is rejected loudly" do
      Application.put_env(:ex_bashkit, :max_timeout_ms, "nope")

      assert_raise ArgumentError, ~r/:max_timeout_ms must be a positive integer or nil/, fn ->
        Session.new(limits: [timeout_ms: 1_000])
      end
    end
  end

  test "with no ceiling configured, a large :timeout_ms is still accepted" do
    Application.delete_env(:ex_bashkit, :max_timeout_ms)
    session = Session.new(limits: [timeout_ms: 600_000])
    assert {:ok, %Result{}} = Session.exec(session, "true")
  end
end
