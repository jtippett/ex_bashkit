# Run with:  mix run examples/mounts.exs
#
# Host directory mounts: give a sandbox controlled access to real host dirs,
# with bashkit enforcing read-only/read-write modes and escape protection.

alias ExBashkit.Session

# Set up a real host workspace: a read-only "inputs" dir and a writable "out" dir.
base = Path.join(System.tmp_dir!(), "exbashkit-mounts-demo-#{System.unique_integer([:positive])}")
inputs = Path.join(base, "inputs")
out = Path.join(base, "out")
File.mkdir_p!(inputs)
File.mkdir_p!(out)
File.write!(Path.join(inputs, "data.txt"), "north,10\nsouth,20\nnorth,5\n")

session =
  Session.new(
    mounts: [
      {"/in", inputs, :read_only},
      {"/out", out, :read_write}
    ],
    # On macOS, temp dirs live under /private (sensitive), so allowlist our base.
    allowed_mount_paths: [base]
  )

# The script reads real host inputs and writes real host output.
{:ok, %ExBashkit.Result{exit_code: 0}} =
  Session.exec(session, """
  awk -F, '{ sum[$1] += $2 } END { for (k in sum) print k, sum[k] }' /in/data.txt \
    | sort > /out/totals.txt
  """)

IO.puts("# Host file written by the sandbox at #{Path.join(out, "totals.txt")}:")
IO.write(File.read!(Path.join(out, "totals.txt")))

# The read-only mount really is read-only: a write fails and the host is untouched.
{:ok, %ExBashkit.Result{exit_code: code, stderr: err}} =
  Session.exec(session, "echo tampering > /in/data.txt")

IO.puts("\n# Writing to the read-only mount failed (exit #{code}):")
IO.write([IO.ANSI.yellow(), String.trim_trailing(err), IO.ANSI.reset(), "\n"])
IO.puts("# Host input still intact: #{inspect(File.read!(Path.join(inputs, "data.txt")))}")

File.rm_rf!(base)
