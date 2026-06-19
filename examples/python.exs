# Run with:  mix run examples/python.exs
#
# Sandboxed Python inside a bash session, sharing the session's filesystem.
# Requires the optional :ex_monty dependency (a path/dev dep in this repo).
#
# A bash step writes a file; a `python` step reads it, computes, and writes a
# result; a final bash step reads *that* — all over one shared virtual
# filesystem, exactly as in a real shell. Python runs fully sandboxed: only the
# filesystem and os.getenv are reachable (no network, no clock).

alias ExBashkit.{Result, Session}

unless Code.ensure_loaded?(ExMonty) do
  IO.puts("This example needs the optional :ex_monty dependency. Add it to deps and retry.")
  System.halt(0)
end

session = Session.new(python: true)

defmodule Demo do
  def show(session, label, script) do
    case Session.exec(session, script) do
      {:ok, %Result{stdout: out, stderr: err, exit_code: code}} ->
        IO.puts("\n# #{label}  (exit #{code})")
        if out != "", do: IO.write(out)
        if err != "", do: IO.write([IO.ANSI.yellow(), err, IO.ANSI.reset()])

      {:error, message} ->
        IO.puts("\n# #{label}  (error)")
        IO.puts([IO.ANSI.red(), message, IO.ANSI.reset()])
    end
  end
end

# --- inline one-liner ---
Demo.show(session, "inline (-c)", "python -c 'print(\"hello from python\")'")

# --- a bash/python/bash pipeline over the shared filesystem ---
Demo.show(session, "bash writes input", "printf '4\\n8\\n15\\n16\\n23\\n42\\n' > /nums.txt; echo wrote /nums.txt")

program = """
from pathlib import Path
nums = [int(x) for x in Path('/nums.txt').read_text().split()]
Path('/stats.txt').write_text(f"count={len(nums)} sum={sum(nums)} max={max(nums)}\\n")
print("python processed", len(nums), "numbers")
"""

Demo.show(session, "python reads, computes, writes", "cat > /run.py <<'EOF'\n#{program}EOF\npython /run.py")

Demo.show(session, "bash reads python's output", "cat /stats.txt")

# --- a Python error fails only that command; the session stays usable ---
Demo.show(session, "a python error is isolated", "python -c 'print(1/0)'")
Demo.show(session, "session still works", "echo 'still going'")
