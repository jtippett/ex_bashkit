defmodule ExBashkit.SessionFsApiTest do
  use ExUnit.Case, async: true

  alias ExBashkit.Session

  # Host-side filesystem primitives over the session's (shared) in-memory/host
  # VFS — the introspection/mutation surface the Python bridge routes Python's
  # pathlib/os calls through, and useful on their own. All lock-free (no bash
  # lock), so they work mid-script too.

  describe "stat/2" do
    test "reports a file's type and size" do
      s = Session.new()
      assert {:ok, _} = Session.exec(s, "printf '12345' > /f.txt")
      assert {:ok, %{type: :file, size: 5}} = Session.stat(s, "/f.txt")
    end

    test "reports a directory" do
      s = Session.new()
      assert {:ok, _} = Session.exec(s, "mkdir /d")
      assert {:ok, %{type: :dir}} = Session.stat(s, "/d")
    end

    test "a missing path is an error" do
      s = Session.new()
      assert {:error, message} = Session.stat(s, "/nope")
      assert is_binary(message)
    end
  end

  describe "list_dir/2" do
    test "lists entries with their types" do
      s = Session.new()
      assert {:ok, _} = Session.exec(s, "mkdir -p /d/sub; echo x > /d/a.txt")
      assert {:ok, entries} = Session.list_dir(s, "/d")
      assert {"a.txt", :file} in entries
      assert {"sub", :dir} in entries
    end

    test "a missing directory is an error" do
      s = Session.new()
      assert {:error, _} = Session.list_dir(s, "/missing")
    end
  end

  describe "mkdir/3" do
    test "creates a directory" do
      s = Session.new()
      assert :ok = Session.mkdir(s, "/new")
      assert {:ok, %{type: :dir}} = Session.stat(s, "/new")
    end

    test "without :parents a missing parent fails" do
      s = Session.new()
      assert {:error, _} = Session.mkdir(s, "/a/b/c")
    end

    test "with parents: true creates the whole chain" do
      s = Session.new()
      assert :ok = Session.mkdir(s, "/a/b/c", parents: true)
      assert {:ok, %{type: :dir}} = Session.stat(s, "/a/b/c")
    end

    test "parents: true is idempotent on an existing directory" do
      s = Session.new()
      assert :ok = Session.mkdir(s, "/x", parents: true)
      assert :ok = Session.mkdir(s, "/x", parents: true)
    end
  end

  describe "remove/3" do
    test "removes a file" do
      s = Session.new()
      assert {:ok, _} = Session.exec(s, "echo x > /f")
      assert :ok = Session.remove(s, "/f")
      assert {:error, _} = Session.stat(s, "/f")
    end

    test "a non-empty directory needs recursive: true" do
      s = Session.new()
      assert {:ok, _} = Session.exec(s, "mkdir /d; echo x > /d/f")
      assert {:error, _} = Session.remove(s, "/d")
      assert :ok = Session.remove(s, "/d", recursive: true)
      assert {:error, _} = Session.stat(s, "/d")
    end
  end

  describe "rename/3" do
    test "moves a file" do
      s = Session.new()
      assert {:ok, _} = Session.exec(s, "echo hi > /old")
      assert :ok = Session.rename(s, "/old", "/new")
      assert {:error, _} = Session.stat(s, "/old")
      assert {:ok, "hi\n"} = Session.read_file(s, "/new")
    end
  end
end
