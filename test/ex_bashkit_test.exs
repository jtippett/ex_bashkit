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
      # A file that certainly exists on the host is not visible in the sandbox.
      host_file = Path.expand("mix.exs")
      assert File.exists?(host_file)

      assert {:ok, %ExBashkit.Result{exit_code: code}} =
               ExBashkit.exec("cat '#{host_file}'")

      assert code != 0
    end

    test "/etc/passwd is bashkit's synthetic root filesystem, not the host's" do
      # Since bashkit 0.19 the sandbox ships a default root filesystem with
      # stand-in system files, so scripts that read them keep working.
      assert {:ok, %ExBashkit.Result{stdout: passwd, exit_code: 0}} =
               ExBashkit.exec("cat /etc/passwd")

      assert passwd =~ "sandbox:x:1000:1000"
      refute passwd == File.read!("/etc/passwd")
    end

    test "jq is bundled (the bashkit `jq` feature is enabled in the NIF)" do
      assert {:ok, %ExBashkit.Result{stdout: "42\n", exit_code: 0}} =
               ExBashkit.exec(~s(echo '{"a":42}' | jq '.a'))
    end
  end
end
