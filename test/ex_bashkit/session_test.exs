defmodule ExBashkit.SessionTest do
  use ExUnit.Case, async: true
  doctest ExBashkit.Session

  alias ExBashkit.Session

  describe "new/1 and exec/2 — state persistence" do
    test "environment variables set by a script persist across calls" do
      session = Session.new()
      assert {:ok, _} = Session.exec(session, "export FOO=bar")
      assert {:ok, %ExBashkit.Result{stdout: "bar\n"}} = Session.exec(session, "echo $FOO")
    end

    test "the current working directory persists across calls" do
      session = Session.new()
      assert {:ok, _} = Session.exec(session, "cd /tmp")
      assert {:ok, %ExBashkit.Result{stdout: "/tmp\n"}} = Session.exec(session, "pwd")
    end

    test "files (and directories) written to the virtual filesystem persist across calls" do
      session = Session.new()
      assert {:ok, _} = Session.exec(session, "mkdir -p /work")
      assert {:ok, _} = Session.exec(session, "echo persisted > /work/note.txt")

      assert {:ok, %ExBashkit.Result{stdout: "persisted\n"}} =
               Session.exec(session, "cat /work/note.txt")
    end

    test "shell functions defined in one call are callable in the next" do
      session = Session.new()
      assert {:ok, _} = Session.exec(session, "greet() { echo \"hi $1\"; }")

      assert {:ok, %ExBashkit.Result{stdout: "hi sam\n"}} =
               Session.exec(session, "greet sam")
    end

    test "separate sessions do not share state" do
      a = Session.new()
      b = Session.new()
      assert {:ok, _} = Session.exec(a, "export SECRET=a")
      assert {:ok, %ExBashkit.Result{stdout: "\n"}} = Session.exec(b, "echo $SECRET")
    end
  end

  describe "new/1 — builder options" do
    test "seeds environment variables from :env (map)" do
      session = Session.new(env: %{"GREETING" => "hej"})
      assert {:ok, %ExBashkit.Result{stdout: "hej\n"}} = Session.exec(session, "echo $GREETING")
    end

    test "seeds environment variables from :env (keyword list)" do
      session = Session.new(env: [LANG: "C"])
      assert {:ok, %ExBashkit.Result{stdout: "C\n"}} = Session.exec(session, "echo $LANG")
    end

    test "sets the starting :cwd" do
      session = Session.new(cwd: "/tmp")
      assert {:ok, %ExBashkit.Result{stdout: "/tmp\n"}} = Session.exec(session, "pwd")
    end

    test "sets the virtual :username (reflected by whoami)" do
      session = Session.new(username: "alice")
      assert {:ok, %ExBashkit.Result{stdout: "alice\n"}} = Session.exec(session, "whoami")
    end

    test "sets the virtual :hostname (reflected by hostname)" do
      session = Session.new(hostname: "my-server")
      assert {:ok, %ExBashkit.Result{stdout: "my-server\n"}} = Session.exec(session, "hostname")
    end

    test "defaults match bashkit's sandbox identity" do
      session = Session.new()
      assert {:ok, %ExBashkit.Result{stdout: "sandbox\n"}} = Session.exec(session, "whoami")

      assert {:ok, %ExBashkit.Result{stdout: "bashkit-sandbox\n"}} =
               Session.exec(session, "hostname")
    end
  end

  describe "exec/2 — result semantics" do
    test "a non-zero exit is still {:ok, ...}" do
      session = Session.new()
      assert {:ok, %ExBashkit.Result{exit_code: 1}} = Session.exec(session, "false")
    end

    test "stderr is captured separately" do
      session = Session.new()
      assert {:ok, %ExBashkit.Result{stderr: stderr}} = Session.exec(session, "echo oops 1>&2")
      assert stderr =~ "oops"
    end
  end
end
