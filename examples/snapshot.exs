# Run with:  mix run examples/snapshot.exs
#
# Snapshot & resume: capture a session's state to a binary, then reload it into a
# fresh session — simulating a process restart or a move to another node. The
# snapshot carries shell state (vars, env, cwd, functions) and in-memory
# filesystem contents, but NOT session config (builtins, mounts, limits): to
# resume a configured session you rebuild it with the same capabilities and then
# restore into it.

alias ExBashkit.{Result, Session}

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

# --- 1. Build up some state in a session ---
original = Session.new()
Demo.show(original, "set state", "x=42; greet() { echo \"hi from $1\"; }; echo work > /notes.txt")
Demo.show(original, "use state", "echo $x; greet bash; cat /notes.txt")

# --- 2. Snapshot it to bytes you could persist anywhere ---
{:ok, bytes} = Session.snapshot(original)
IO.puts("\n# snapshot is #{byte_size(bytes)} bytes")

# --- 3. "Restart": a brand-new session knows nothing... ---
resumed = Session.new()
Demo.show(resumed, "fresh session (pre-restore)", "echo \"x=[$x]\"; cat /notes.txt")

# --- ...until we restore the snapshot into it ---
{:ok, resumed} = Session.restore(resumed, bytes)
Demo.show(resumed, "resumed (post-restore)", "echo $x; greet again; cat /notes.txt")

# --- 4. Crossing a trust boundary: HMAC-keyed snapshots ---
# When a snapshot travels over a network or shared storage, key it. The matching
# key is required to restore; a wrong key or tampered bytes are rejected.
secret = "shared-secret-key"
{:ok, keyed} = Session.snapshot(original, key: secret)

target = Session.new()

case Session.restore(target, keyed, key: "WRONG-key") do
  {:error, msg} -> IO.puts("\n# wrong key rejected: #{msg}")
  {:ok, _} -> IO.puts("\n# (unexpected) wrong key accepted")
end

{:ok, target} = Session.restore(target, keyed, key: secret)
Demo.show(target, "keyed restore (correct key)", "echo $x")
