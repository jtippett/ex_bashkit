defmodule ExBashkit.SessionVfsTest do
  use ExUnit.Case, async: true

  alias ExBashkit.Session

  describe "new/1 :files seeding" do
    test "seeds a file readable by a script, creating parent dirs" do
      session = Session.new(files: %{"/data/config.txt" => "debug=true\n"})

      assert {:ok, %ExBashkit.Result{stdout: "debug=true\n"}} =
               Session.exec(session, "cat /data/config.txt")
    end

    test "seeds multiple files" do
      session =
        Session.new(files: %{"/a.txt" => "alpha\n", "/b.txt" => "beta\n"})

      assert {:ok, %ExBashkit.Result{stdout: "alpha\nbeta\n"}} =
               Session.exec(session, "cat /a.txt /b.txt")
    end

    test "seeded files are independent per session" do
      a = Session.new(files: %{"/secret" => "in-a\n"})
      b = Session.new()

      assert {:ok, %ExBashkit.Result{stdout: "in-a\n"}} = Session.exec(a, "cat /secret")
      assert {:ok, %ExBashkit.Result{exit_code: code}} = Session.exec(b, "cat /secret")
      assert code != 0
    end

    test "accepts iodata content" do
      session = Session.new(files: %{"/joined" => ["a", ?b, ["c"]]})
      assert {:ok, %ExBashkit.Result{stdout: "abc"}} = Session.exec(session, "cat /joined")
    end
  end

  describe "write_file/3 and read_file/2" do
    test "host can write a file a script then reads" do
      session = Session.new()
      assert :ok = Session.write_file(session, "/notes.txt", "hello\n")

      assert {:ok, %ExBashkit.Result{stdout: "hello\n"}} =
               Session.exec(session, "cat /notes.txt")
    end

    test "host can read a file a script wrote" do
      session = Session.new()
      assert {:ok, _} = Session.exec(session, "echo from-script > /s.txt")
      assert {:ok, "from-script\n"} = Session.read_file(session, "/s.txt")
    end

    test "round-trips arbitrary binary content" do
      session = Session.new()
      blob = <<0, 1, 2, 254, 255>>
      assert :ok = Session.write_file(session, "/blob.bin", blob)
      assert {:ok, ^blob} = Session.read_file(session, "/blob.bin")
    end

    test "reading a missing file returns {:error, _}" do
      session = Session.new()
      assert {:error, _} = Session.read_file(session, "/nope.txt")
    end

    test "writes persist for later calls in the same session" do
      session = Session.new()
      assert :ok = Session.write_file(session, "/state", "v1")
      assert {:ok, "v1"} = Session.read_file(session, "/state")
      assert {:ok, _} = Session.exec(session, "echo -n v2 > /state")
      assert {:ok, "v2"} = Session.read_file(session, "/state")
    end
  end

  describe "path resolution and error cases" do
    test "paths resolve from the filesystem root, independent of session cwd" do
      session = Session.new(cwd: "/work")
      assert {:ok, _} = Session.exec(session, "mkdir -p /work && echo hi > /work/out.txt")

      # The script wrote /work/out.txt; a bare relative path reads /out.txt.
      assert {:error, _} = Session.read_file(session, "out.txt")
      # The absolute path resolves.
      assert {:ok, "hi\n"} = Session.read_file(session, "/work/out.txt")
    end

    test "writing under a path whose parent is a file returns {:error, _}" do
      session = Session.new()
      assert :ok = Session.write_file(session, "/a", "i am a file")
      assert {:error, _} = Session.write_file(session, "/a/b", "nope")
    end

    test "reading a directory returns {:error, _}" do
      session = Session.new()
      assert {:ok, _} = Session.exec(session, "mkdir -p /d")
      assert {:error, _} = Session.read_file(session, "/d")
    end

    test "writing to the root path returns {:error, _}" do
      session = Session.new()
      assert {:error, _} = Session.write_file(session, "/", "nope")
    end
  end
end
