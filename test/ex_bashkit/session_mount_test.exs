defmodule ExBashkit.SessionMountTest do
  # Touches the real host filesystem (tmp dirs), so not async.
  use ExUnit.Case, async: false

  alias ExBashkit.Session

  setup do
    root = Path.join(System.tmp_dir!(), "exbashkit-mnt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  describe ":read_only mounts" do
    test "a script reads host files through the mount", %{root: root} do
      File.write!(Path.join(root, "greeting.txt"), "hello from host\n")
      session = Session.new(mounts: [{"/data", root, :read_only}], allowed_mount_paths: [root])

      assert {:ok, %ExBashkit.Result{stdout: "hello from host\n"}} =
               Session.exec(session, "cat /data/greeting.txt")
    end

    test "writes through a read-only mount fail and don't touch the host", %{root: root} do
      session = Session.new(mounts: [{"/data", root, :read_only}], allowed_mount_paths: [root])

      assert {:ok, %ExBashkit.Result{exit_code: code}} =
               Session.exec(session, "echo nope > /data/new.txt")

      assert code != 0
      refute File.exists?(Path.join(root, "new.txt"))
    end
  end

  describe ":read_write mounts" do
    test "a script's writes land on the real host filesystem", %{root: root} do
      session = Session.new(mounts: [{"/work", root, :read_write}], allowed_mount_paths: [root])

      assert {:ok, %ExBashkit.Result{exit_code: 0}} =
               Session.exec(session, "echo produced > /work/out.txt")

      assert File.read!(Path.join(root, "out.txt")) == "produced\n"
    end
  end

  describe "sandbox-escape protection (delegated to bashkit)" do
    test "a symlink pointing outside the mount root cannot be read", %{root: root} do
      # Secret lives OUTSIDE the mounted directory.
      outside =
        Path.join(System.tmp_dir!(), "exbashkit-secret-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "do not leak")
      on_exit(fn -> File.rm_rf!(outside) end)

      # A legit file inside the mount, plus a symlink that escapes to the secret.
      File.write!(Path.join(root, "ok.txt"), "legit\n")
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "leak"))

      session = Session.new(mounts: [{"/m", root, :read_only}], allowed_mount_paths: [root])

      # The mount is genuinely live (so the next assertion proves containment,
      # not just an absent mount)...
      assert {:ok, %ExBashkit.Result{stdout: "legit\n"}} = Session.exec(session, "cat /m/ok.txt")
      # ...but the escaping symlink is refused.
      assert {:ok, %ExBashkit.Result{exit_code: code}} = Session.exec(session, "cat /m/leak")
      assert code != 0
    end

    test "a .. path cannot escape the mount root", %{root: root} do
      File.write!(Path.join(root, "inside.txt"), "inside\n")
      File.write!(Path.join(System.tmp_dir!(), "exbashkit-escape-marker"), "outside")
      session = Session.new(mounts: [{"/m", root, :read_only}], allowed_mount_paths: [root])

      # The mount is live...
      assert {:ok, %ExBashkit.Result{stdout: "inside\n"}} =
               Session.exec(session, "cat /m/inside.txt")

      # ...but `..` cannot climb out of it.
      assert {:ok, %ExBashkit.Result{exit_code: code}} =
               Session.exec(session, "cat /m/../exbashkit-escape-marker")

      assert code != 0
    end
  end

  describe "sensitive host paths" do
    test "a sensitive host path without an allowlist raises (not silently skipped)" do
      # /etc is on bashkit's sensitive default-deny list. Without an allowlist the
      # mount would be silently dropped; new/1 must surface that as an error.
      assert_raise ArgumentError, ~r/rejected/, fn ->
        Session.new(mounts: [{"/etc_ro", "/etc", :read_only}])
      end
    end

    test "allowlisting a sensitive host path lets the mount through" do
      session =
        Session.new(mounts: [{"/etc_ro", "/etc", :read_only}], allowed_mount_paths: ["/etc"])

      assert {:ok, %ExBashkit.Result{exit_code: 0}} = Session.exec(session, "test -d /etc_ro")
    end
  end

  describe "validation" do
    test "mounting a non-existent host directory raises", %{root: root} do
      missing = Path.join(root, "does-not-exist")

      assert_raise ArgumentError, ~r/does-not-exist/, fn ->
        Session.new(mounts: [{"/x", missing, :read_only}])
      end
    end

    test "mounting a file (not a directory) raises", %{root: root} do
      file = Path.join(root, "a-file")
      File.write!(file, "i am a file")

      assert_raise ArgumentError, fn ->
        Session.new(mounts: [{"/x", file, :read_only}])
      end
    end

    test "an unknown mode raises", %{root: root} do
      assert_raise ArgumentError, ~r/mode/, fn ->
        Session.new(mounts: [{"/x", root, :sideways}])
      end
    end

    test "a relative vfs path raises", %{root: root} do
      assert_raise ArgumentError, ~r/absolute/, fn ->
        Session.new(mounts: [{"data", root, :read_only}])
      end
    end

    test "a malformed mounts entry raises ArgumentError", %{root: root} do
      assert_raise ArgumentError, fn ->
        Session.new(mounts: [{"/x", root}])
      end
    end
  end

  describe "mounts compose with other options" do
    test "mounts coexist with env, cwd, and the in-memory filesystem", %{root: root} do
      File.write!(Path.join(root, "host.txt"), "H\n")

      session =
        Session.new(
          mounts: [{"/data", root, :read_only}],
          allowed_mount_paths: [root],
          env: %{"WHO" => "tester"},
          files: %{"/mem.txt" => "M\n"}
        )

      assert {:ok, %ExBashkit.Result{stdout: "tester H M\n"}} =
               Session.exec(session, ~s|echo "$WHO $(cat /data/host.txt) $(cat /mem.txt)"|)
    end
  end
end
