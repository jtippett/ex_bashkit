defmodule ExBashkitTest do
  use ExUnit.Case, async: true
  doctest ExBashkit

  describe "exec/1" do
    test "captures stdout" do
      assert {:ok, %ExBashkit.Result{stdout: "hello\n", exit_code: 0}} =
               ExBashkit.exec("echo hello")
    end

    test "pipelines run through reimplemented builtins" do
      assert {:ok, %ExBashkit.Result{stdout: "HELLO\n"}} =
               ExBashkit.exec("echo hello | tr a-z A-Z")
    end

    test "a non-zero exit is still {:ok, ...} — the script ran" do
      assert {:ok, %ExBashkit.Result{exit_code: 1}} = ExBashkit.exec("false")
    end

    test "stderr is captured separately" do
      assert {:ok, %ExBashkit.Result{stderr: stderr}} =
               ExBashkit.exec("echo oops 1>&2")

      assert stderr =~ "oops"
    end

    test "the sandbox has no host filesystem" do
      # /etc/passwd does not exist in the virtual FS.
      assert {:ok, %ExBashkit.Result{exit_code: code}} =
               ExBashkit.exec("cat /etc/passwd")

      assert code != 0
    end
  end
end
