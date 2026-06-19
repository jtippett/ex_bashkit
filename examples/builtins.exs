# Run with:  mix run examples/builtins.exs
#
# Custom builtins: register Elixir functions as virtual executables a sandboxed
# script can call. The script reaches capabilities the host controls — here a
# tiny in-memory key/value store and a "now" clock — with no real process or
# network access.

alias ExBashkit.{Result, Session}

store = %{"answer" => "42", "greeting" => "hello"}

session =
  Session.new(
    builtin_timeout_ms: 1_000,
    builtins: %{
      # {:ok, iodata} -> stdout, exit 0
      "kv_get" => fn call ->
        case Map.fetch(store, hd(call.args)) do
          {:ok, value} -> {:ok, value <> "\n"}
          # {:error, iodata} -> stderr, exit 1
          :error -> {:error, "kv_get: no such key: #{hd(call.args)}\n"}
        end
      end,

      # Reads piped stdin and uppercases it.
      "shout" => fn call -> {:ok, String.upcase(call.stdin)} end,

      # Full control via %Result{} — custom exit code.
      "coin" => fn _call -> %Result{stdout: "tails\n", exit_code: 0} end
    }
  )

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

# A builtin's output composes with the shell like any command.
Demo.show(session, "command substitution", "echo \"the answer is $(kv_get answer)\"")

# Pipe a real builtin's output into a custom one.
Demo.show(session, "pipe into a builtin", "echo hello world | shout")

# A missing key fails the command (exit 1) but not the session.
Demo.show(session, "error path", "kv_get nope")

# The session is still fully usable afterward.
Demo.show(session, "session still works", "coin; echo done")
