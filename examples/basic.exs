# Run with:  mix run examples/basic.exs
#
# A tour of what the sandbox can (and can't) do today.

defmodule Demo do
  def run(label, script) do
    case ExBashkit.exec(script) do
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

Demo.run("pipes + reimplemented builtins", "echo 'hello world' | tr a-z A-Z | rev")
Demo.run("arithmetic + loops", "for i in 1 2 3 4 5; do echo $((i * i)); done")
Demo.run("virtual filesystem", """
mkdir -p /work
echo 'persisted in-memory' > /work/note.txt
cat /work/note.txt
""")
Demo.run("no host filesystem", "cat /etc/passwd")
Demo.run("text processing", """
printf 'banana\\napple\\ncherry\\napple\\n' | sort | uniq -c
""")
