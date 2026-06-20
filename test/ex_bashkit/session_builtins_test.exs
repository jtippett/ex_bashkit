defmodule ExBashkit.SessionBuiltinsTest do
  use ExUnit.Case, async: true

  alias ExBashkit.{Result, Session}

  describe "the call map (args / stdin / env)" do
    test "a builtin receives its arguments (sans command name)" do
      session =
        Session.new(builtins: %{"myargs" => fn call -> {:ok, Enum.join(call.args, ",")} end})

      assert {:ok, %Result{stdout: "a,b,c", exit_code: 0}} =
               Session.exec(session, "myargs a b c")
    end

    test "a builtin receives piped stdin" do
      session =
        Session.new(builtins: %{"up" => fn call -> {:ok, String.upcase(call.stdin)} end})

      assert {:ok, %Result{stdout: "HI\n", exit_code: 0}} =
               Session.exec(session, "echo hi | up")
    end

    test "stdin is an empty string when nothing is piped" do
      session =
        Session.new(builtins: %{"len" => fn call -> {:ok, "#{byte_size(call.stdin)}"} end})

      assert {:ok, %Result{stdout: "0"}} = Session.exec(session, "len")
    end

    test "a builtin sees the session environment" do
      session =
        Session.new(
          env: %{"FOO" => "bar"},
          builtins: %{"getfoo" => fn call -> {:ok, Map.get(call.env, "FOO", "?")} end}
        )

      assert {:ok, %Result{stdout: "bar"}} = Session.exec(session, "getfoo")
    end
  end

  describe "return contract" do
    test "{:error, io} becomes stderr and exit 1" do
      session = Session.new(builtins: %{"nope" => fn _ -> {:error, "boom\n"} end})

      assert {:ok, %Result{stderr: "boom\n", exit_code: 1}} = Session.exec(session, "nope")
    end

    test "a %Result{} gives full control over stdout/stderr/exit_code" do
      session =
        Session.new(
          builtins: %{
            "raw" => fn _ -> %Result{stdout: "out", stderr: "warn", exit_code: 3} end
          }
        )

      assert {:ok, %Result{stdout: "out", exit_code: 3}} = Session.exec(session, "raw")
    end

    test "stdout is captured into a pipeline like any command" do
      session = Session.new(builtins: %{"greet" => fn _ -> {:ok, "hello\n"} end})

      assert {:ok, %Result{stdout: "HELLO\n"}} =
               Session.exec(session, "greet | tr a-z A-Z")
    end

    test "an out-of-byte-range exit_code is masked like a real shell (mod 256)" do
      session =
        Session.new(
          builtins: %{
            "big" => fn _ -> %Result{stdout: "", exit_code: 300} end,
            # Past i32 range: must be masked, not crash the (linked) handler.
            "huge" => fn _ -> %Result{stdout: "", exit_code: 5_000_000_000} end,
            "ok" => fn _ -> {:ok, "fine\n"} end
          }
        )

      assert {:ok, %Result{exit_code: 44}} = Session.exec(session, "big")
      assert {:ok, %Result{exit_code: code}} = Session.exec(session, "huge")
      assert code in 0..255
      # Session (and its linked caller) survived the huge value.
      assert {:ok, %Result{stdout: "fine\n"}} = Session.exec(session, "ok")
    end
  end

  describe "failure model" do
    test "a raising handler fails the command (exit 1) without killing the session" do
      session =
        Session.new(
          builtins: %{
            "boom" => fn _ -> raise "kaboom" end,
            "ok" => fn _ -> {:ok, "fine\n"} end
          }
        )

      assert {:ok, %Result{exit_code: 1, stderr: stderr}} = Session.exec(session, "boom")
      assert stderr =~ "boom"

      # Session is still usable after a handler crash.
      assert {:ok, %Result{stdout: "fine\n", exit_code: 0}} = Session.exec(session, "ok")
    end

    test "a malformed return value fails the command (exit 1)" do
      session = Session.new(builtins: %{"weird" => fn _ -> :not_a_valid_return end})

      assert {:ok, %Result{exit_code: 1, stderr: stderr}} = Session.exec(session, "weird")
      assert stderr =~ "weird"
    end

    test "a handler exceeding :builtin_timeout_ms fails with exit 124" do
      session =
        Session.new(
          builtin_timeout_ms: 50,
          builtins: %{
            "slow" => fn _ ->
              Process.sleep(300)
              {:ok, "too late\n"}
            end,
            "ok" => fn _ -> {:ok, "fine\n"} end
          }
        )

      assert {:ok, %Result{exit_code: 124, stderr: stderr}} = Session.exec(session, "slow")
      assert stderr =~ "timed out"

      # Still usable after a timed-out back-call.
      assert {:ok, %Result{stdout: "fine\n"}} = Session.exec(session, "ok")
    end

    test "a timed-out builtin's worker is cancelled when the next command starts" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      session =
        Session.new(
          builtin_timeout_ms: 100,
          builtins: %{
            # Times out at 100ms; only bumps the counter at 500ms — i.e. only if
            # its worker is allowed to keep running past the timeout.
            "slow" => fn _ ->
              Process.sleep(500)
              Agent.update(counter, &(&1 + 1))
              {:ok, ""}
            end,
            "quick" => fn _ -> {:ok, "q\n"} end
          }
        )

      # `slow` times out (exit 124) then `quick` runs; starting `quick` must kill
      # slow's orphaned worker before its 500ms bump.
      assert {:ok, %Result{}} = Session.exec(session, "slow; quick")
      Process.sleep(600)
      assert Agent.get(counter, & &1) == 0
    end

    test "a builtin cancelled by the script timeout doesn't wedge the session" do
      # bashkit's own execution timeout (:limits timeout_ms) fires *while* the
      # builtin is parked awaiting Elixir, dropping the whole exec future. The
      # pending-call slot must still be cleaned up (no leak) and the session must
      # stay usable. :builtin_timeout_ms is deliberately large so the script
      # timeout is the one that fires.
      session =
        Session.new(
          limits: [timeout_ms: 50],
          builtin_timeout_ms: 5_000,
          builtins: %{
            "slow" => fn _ ->
              Process.sleep(400)
              {:ok, "late\n"}
            end,
            "ok" => fn _ -> {:ok, "fine\n"} end
          }
        )

      assert {:error, message} = Session.exec(session, "slow")
      assert is_binary(message)

      assert {:ok, %Result{stdout: "fine\n"}} = Session.exec(session, "ok")
    end
  end

  describe "concurrency" do
    test "custom builtins stay isolated across concurrent sessions" do
      make = fn tag ->
        Session.new(builtins: %{"id" => fn call -> {:ok, "#{tag}:#{hd(call.args)}\n"} end})
      end

      a = make.("A")
      b = make.("B")

      run = fn session -> for i <- 1..25, do: Session.exec(session, "id #{i}") end

      [ra, rb] =
        [Task.async(fn -> run.(a) end), Task.async(fn -> run.(b) end)] |> Task.await_many()

      assert Enum.all?(ra, &match?({:ok, %Result{stdout: "A:" <> _}}, &1))
      assert Enum.all?(rb, &match?({:ok, %Result{stdout: "B:" <> _}}, &1))
      assert {:ok, %Result{stdout: "A:25\n"}} = List.last(ra)
      assert {:ok, %Result{stdout: "B:25\n"}} = List.last(rb)
    end
  end

  describe "cross-session use" do
    test "a builtin may drive a *different* session" do
      inner = Session.new()

      outer =
        Session.new(
          builtins: %{
            "delegate" => fn _ ->
              {:ok, %Result{stdout: out}} = Session.exec(inner, "echo nested")
              {:ok, out}
            end
          }
        )

      assert {:ok, %Result{stdout: "nested\n"}} = Session.exec(outer, "delegate")
    end
  end

  describe "interplay with session state" do
    test "custom builtins coexist with real builtins and persist across calls" do
      session = Session.new(builtins: %{"tag" => fn call -> {:ok, "[#{hd(call.args)}]"} end})

      assert {:ok, _} = Session.exec(session, "export NAME=world")
      assert {:ok, %Result{stdout: "[hi]"}} = Session.exec(session, "tag hi")
      assert {:ok, %Result{stdout: "world\n"}} = Session.exec(session, "echo $NAME")
    end
  end

  describe "validation" do
    test "a non-string builtin name raises" do
      assert_raise ArgumentError, ~r/builtin/, fn ->
        Session.new(builtins: %{:notastring => fn _ -> {:ok, ""} end})
      end
    end

    test "a builtin name with whitespace raises (it could never be invoked)" do
      assert_raise ArgumentError, ~r/builtin/, fn ->
        Session.new(builtins: %{"two words" => fn _ -> {:ok, ""} end})
      end
    end

    test "a non-function builtin value raises" do
      assert_raise ArgumentError, ~r/builtin/, fn ->
        Session.new(builtins: %{"x" => "not a fun"})
      end
    end

    test "a builtin function of the wrong arity raises" do
      assert_raise ArgumentError, ~r/builtin/, fn ->
        Session.new(builtins: %{"x" => fn _a, _b -> {:ok, ""} end})
      end
    end

    test "a non-positive :builtin_timeout_ms raises" do
      assert_raise ArgumentError, ~r/builtin_timeout_ms/, fn ->
        Session.new(builtins: %{"x" => fn _ -> {:ok, ""} end}, builtin_timeout_ms: 0)
      end
    end
  end
end
