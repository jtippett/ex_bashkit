defmodule ExBashkit.SessionLimitsTest do
  use ExUnit.Case, async: true

  alias ExBashkit.Session

  describe ":limits enforcement" do
    test "max_commands caps how many commands a script may run" do
      session = Session.new(limits: [max_commands: 5])

      assert {:error, message} =
               Session.exec(session, "for i in {1..100}; do echo $i; done")

      assert is_binary(message)
    end

    test "max_loop_iterations caps a single loop" do
      session = Session.new(limits: [max_loop_iterations: 5])
      assert {:error, _} = Session.exec(session, "for i in {1..1000}; do :; done")
    end

    test "max_total_loop_iterations caps iterations across nested loops" do
      session = Session.new(limits: [max_total_loop_iterations: 20])

      assert {:error, _} =
               Session.exec(session, "for i in {1..50}; do for j in {1..50}; do :; done; done")
    end

    test "max_function_depth caps recursion" do
      session = Session.new(limits: [max_function_depth: 5])
      script = "rec() { rec; }; rec"
      assert {:error, _} = Session.exec(session, script)
    end

    test "max_input_bytes rejects an oversized script" do
      session = Session.new(limits: [max_input_bytes: 10])

      assert {:error, _} =
               Session.exec(session, "echo this script is definitely longer than ten bytes")
    end

    test "timeout_ms stops a long-running script" do
      # Crank the count limits up so the wall-clock timeout is the only thing
      # that can stop this infinite loop.
      session =
        Session.new(
          limits: [
            max_commands: 1_000_000_000,
            max_loop_iterations: 1_000_000_000,
            max_total_loop_iterations: 1_000_000_000,
            timeout_ms: 50
          ]
        )

      assert {:error, _} = Session.exec(session, "i=0; while true; do i=$((i + 1)); done")
    end

    test "a limit past the platform maximum means unlimited (not a silent revert to default)" do
      # 10**30 exceeds usize; it must mean "effectively unlimited", not fall back
      # to bashkit's default cap (10_000), which would reject this 50k-iteration loop.
      session = Session.new(limits: [max_commands: 10 ** 30, max_loop_iterations: 10 ** 30])

      assert {:ok, %ExBashkit.Result{exit_code: 0}} =
               Session.exec(session, "for i in {1..50000}; do :; done")
    end
  end

  describe ":limits defaults and acceptance" do
    test "without limits, a moderately heavy script runs fine" do
      session = Session.new()

      assert {:ok, %ExBashkit.Result{exit_code: 0}} =
               Session.exec(session, "for i in {1..1000}; do :; done")
    end

    test "a generous explicit limit still allows normal execution" do
      session = Session.new(limits: [max_commands: 10_000, timeout_ms: 5_000])
      assert {:ok, %ExBashkit.Result{stdout: "hi\n"}} = Session.exec(session, "echo hi")
    end

    test "limits accepts a map as well as a keyword list" do
      session = Session.new(limits: %{max_loop_iterations: 5})
      assert {:error, _} = Session.exec(session, "for i in {1..1000}; do :; done")
    end
  end

  describe ":limits validation" do
    test "an unknown limit key raises" do
      assert_raise ArgumentError, ~r/unknown limit/, fn ->
        Session.new(limits: [bogus_limit: 5])
      end
    end

    test "a non-integer limit value raises" do
      assert_raise ArgumentError, fn ->
        Session.new(limits: [max_commands: "lots"])
      end
    end

    test "a negative limit value raises" do
      assert_raise ArgumentError, fn ->
        Session.new(limits: [max_commands: -1])
      end
    end

    test "timeout_ms: 0 raises (it would time out immediately)" do
      assert_raise ArgumentError, ~r/timeout_ms/, fn ->
        Session.new(limits: [timeout_ms: 0])
      end
    end
  end
end
