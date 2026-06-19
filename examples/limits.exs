# Run with:  mix run examples/limits.exs
#
# Resource limits: bound untrusted scripts so a runaway can't burn the host.

alias ExBashkit.Session

defmodule Demo do
  def show(session, label, script) do
    case Session.exec(session, script) do
      {:ok, %ExBashkit.Result{stdout: out, exit_code: code}} ->
        IO.puts("\n# #{label}  (ok, exit #{code})")
        if out != "", do: IO.write(out)

      {:error, message} ->
        IO.puts("\n# #{label}  (stopped)")
        IO.puts([IO.ANSI.yellow(), message, IO.ANSI.reset()])
    end
  end
end

# A tightly bounded session for running untrusted bash.
session =
  Session.new(
    limits: [
      max_commands: 100,
      max_loop_iterations: 50,
      max_function_depth: 10,
      timeout_ms: 1_000
    ]
  )

# Normal work within budget succeeds.
Demo.show(session, "small loop is fine", "for i in {1..10}; do echo -n .; done; echo")

# A runaway loop is stopped by the command/iteration budget.
Demo.show(session, "runaway loop", "i=0; while true; do i=$((i + 1)); done")

# Unbounded recursion is stopped by max_function_depth.
Demo.show(session, "infinite recursion", "boom() { boom; }; boom")

# A command flood is stopped by max_commands.
Demo.show(session, "command flood", String.duplicate("true; ", 500))
