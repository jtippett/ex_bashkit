# Run with:  mix run examples/vfs.exs
#
# The virtual filesystem as a host<->script data channel: seed inputs from
# Elixir, run a script that processes them, read the results back out.

alias ExBashkit.Session

# Seed inputs up front. Parent directories are created automatically.
session =
  Session.new(
    files: %{
      "/in/sales.csv" => """
      region,amount
      west,100
      east,250
      west,75
      east,50
      """
    }
  )

# You can also stage a file at any time, not just at construction.
:ok = Session.write_file(session, "/in/report.sh", """
#!/usr/bin/env bash
# Sum amounts per region into /out/totals.txt
mkdir -p /out
tail -n +2 /in/sales.csv \
  | awk -F, '{ sum[$1] += $2 } END { for (r in sum) print r, sum[r] }' \
  | sort > /out/totals.txt
""")

{:ok, %ExBashkit.Result{exit_code: 0}} = Session.exec(session, "bash /in/report.sh")

# Pull the result back out — no script needed to inspect it.
{:ok, totals} = Session.read_file(session, "/out/totals.txt")
IO.puts("# /out/totals.txt produced by the sandbox:")
IO.write(totals)

# write_file / read_file round-trip raw bytes — including NUL — untouched.
blob = <<0, 1, 2, "BIN">>
:ok = Session.write_file(session, "/out/blob", blob)
{:ok, ^blob} = Session.read_file(session, "/out/blob")
# The script sees the same bytes (wc -c counts all 6, NUL included).
{:ok, %ExBashkit.Result{stdout: size}} = Session.exec(session, "wc -c < /out/blob")
IO.puts("\n# /out/blob round-tripped #{byte_size(blob)} raw bytes (script wc -c: #{String.trim(size)})")
