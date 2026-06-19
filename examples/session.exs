# Run with:  mix run examples/session.exs
#
# Persistent sessions: state carries across calls, like an interactive shell.

alias ExBashkit.Session

defmodule Demo do
  def step(session, label, script) do
    case Session.exec(session, script) do
      {:ok, %ExBashkit.Result{stdout: out, stderr: err, exit_code: code}} ->
        IO.puts("\n# #{label}  (exit #{code})")
        if out != "", do: IO.write(out)
        if err != "", do: IO.write([IO.ANSI.yellow(), err, IO.ANSI.reset()])

      {:error, message} ->
        IO.puts("\n# #{label}  (interpreter error)")
        IO.puts([IO.ANSI.red(), message, IO.ANSI.reset()])
    end
  end
end

# A bare session starts with bashkit's default sandbox identity.
session = Session.new()

Demo.step(session, "env vars persist", "export PROJECT=ex_bashkit")
Demo.step(session, "...and are visible later", "echo \"building $PROJECT\"")

Demo.step(session, "cwd persists", "mkdir -p /work && cd /work && pwd")
Demo.step(session, "...so relative paths resolve against it", "echo notes > todo.txt && cat /work/todo.txt")

Demo.step(session, "shell functions persist", "tax() { echo $(($1 * 110 / 100)); }")
Demo.step(session, "...and stay callable", "tax 100")

# A second session is fully independent — none of the above leaks in.
fresh = Session.new()
Demo.step(fresh, "separate session, clean slate", "echo \"PROJECT=[$PROJECT] $(ls /work 2>&1)\"")

# Seed initial state up front via options.
configured =
  Session.new(
    env: %{"LANG" => "C"},
    cwd: "/tmp",
    username: "alice",
    hostname: "build-box"
  )

Demo.step(configured, "seeded identity + env + cwd", "echo \"$(whoami)@$(hostname):$(pwd) LANG=$LANG\"")
