defmodule ExBashkit.SessionVfsMalformedListingTest do
  use ExUnit.Case, async: true

  alias ExBashkit.{Result, Session}

  # A misbehaving/adversarial VirtualFs must never crash the host BEAM. A
  # recursive walker (`find`, `grep -r`) joins each listed entry name onto the
  # parent path; a name that resolves back onto the same directory ("", ".",
  # "..", or a separator-bearing name) makes bashkit's default-unbounded `find`
  # recurse forever, overflowing the native stack (SIGBUS) — a whole-node outage,
  # not a contained sandbox failure. The bridge rejects such names so the walk
  # fails as a bounded error instead. See BUGREPORT-empty-dirname-recursion-sigbus.md.
  #
  # If any test here regressed, the `exec` call would SIGBUS and take down the
  # ExUnit runner itself — so these tests completing at all is the guarantee.

  defmodule MalformedFs do
    @behaviour ExBashkit.VirtualFs

    # The root lists a single directory whose name is supplied per-session via
    # the backend arg, letting each test inject a different poisonous name.
    def list(bad_name, "/"), do: {:ok, [{bad_name, :dir}]}
    def list(_bad_name, _), do: {:ok, [{"file.md", :file}]}
    def stat(_bad_name, _), do: {:ok, %{type: :dir, size: 0}}
    def read(_bad_name, _), do: {:ok, "body\n"}
  end

  # Every directory contains one distinct-named subdirectory -> infinite *depth*.
  # bashkit's own path-resolution depth cap (100 levels) already bounds this; the
  # test locks that guarantee in from ExBashkit's side.
  defmodule InfiniteDepthFs do
    @behaviour ExBashkit.VirtualFs
    def list(_arg, _), do: {:ok, [{"a", :dir}]}
    def stat(_arg, _), do: {:ok, %{type: :dir, size: 0}}
    def read(_arg, _), do: {:ok, "body\n"}
  end

  # A well-formed two-level tree, to prove name validation does not over-reject
  # ordinary listings.
  defmodule GoodFs do
    @behaviour ExBashkit.VirtualFs
    def list(_arg, "/"), do: {:ok, [{"sub", :dir}]}
    def list(_arg, "/sub"), do: {:ok, [{"leaf.txt", :file}]}
    def list(_arg, _), do: {:ok, []}
    def stat(_arg, "/sub/leaf.txt"), do: {:ok, %{type: :file, size: 4}}
    def stat(_arg, _), do: {:ok, %{type: :dir, size: 0}}
    def read(_arg, _), do: {:ok, "leaf\n"}
  end

  defp find_under_mount(bad_name) do
    session = Session.new(virtual_fs: %{"/mnt" => {MalformedFs, bad_name}})
    Session.exec(session, "find /mnt -type f")
  end

  for {label, bad_name} <- [
        {"empty", ""},
        {"dot", "."},
        {"dotdot", ".."},
        {"separator", "a/b"},
        {"leading separator", "/etc"}
      ] do
    @tag timeout: 20_000
    test "a #{label} directory-entry name fails the walk as a bounded error, no crash" do
      assert {:ok, %Result{exit_code: exit_code, stderr: stderr}} =
               find_under_mount(unquote(bad_name))

      # find surfaces the rejected listing as a non-zero exit with a diagnostic,
      # rather than recursing into a native crash.
      assert exit_code != 0
      assert stderr =~ "find:"
    end
  end

  @tag timeout: 20_000
  test "unbounded directory *depth* is bounded by bashkit's depth cap, not a crash" do
    session = Session.new(virtual_fs: %{"/mnt" => {InfiniteDepthFs, nil}})

    assert {:ok, %Result{exit_code: 1, stderr: stderr}} =
             Session.exec(session, "find /mnt -type f")

    assert stderr =~ "too deep"
  end

  test "a well-formed nested listing still traverses (validation does not over-reject)" do
    session = Session.new(virtual_fs: %{"/mnt" => {GoodFs, nil}})

    assert {:ok, %Result{exit_code: 0, stdout: stdout}} =
             Session.exec(session, "find /mnt -type f")

    assert stdout =~ "/mnt/sub/leaf.txt"
  end
end
