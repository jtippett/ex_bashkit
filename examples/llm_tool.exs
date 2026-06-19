# Run with:  mix run examples/llm_tool.exs
#
# Using an ExBashkit session as an LLM "bash" tool.
#
# There is deliberately no ExBashkit.Tool module — wiring a sandbox to an LLM is
# a handful of plain data (a JSON schema, a system prompt, and a function that
# runs a tool call and formats the result), and every framework wants that data
# in its own shape. This example is that recipe, framework-neutral, plus a
# ReqLLM snippet at the bottom. It runs offline: the "model" is simulated, so the
# bash/tool half is real and the LLM half is the code you'd adapt.

alias ExBashkit.{Result, Session}

defmodule BashTool do
  @moduledoc "A session-as-tool: the schema/prompt to give an LLM, and the executor."

  # Mirrors bashkit's own BashTool request contract.
  def schema do
    %{
      "type" => "object",
      "required" => ["commands"],
      "properties" => %{
        "commands" => %{"type" => "string", "description" => "Bash commands to execute"}
      }
    }
  end

  def description,
    do: "Run bash commands in a sandboxed virtual Linux shell and return their output."

  # Describe THIS sandbox accurately so the model uses it well. Tailor it to the
  # session's configured capabilities (network, python, mounts, …).
  def system_prompt(opts \\ []) do
    python = if opts[:python], do: " A `python3` interpreter is available.", else: ""

    """
    You have a `bash` tool: it runs commands in a sandboxed, in-memory virtual \
    Linux shell. State persists across calls within the session — environment \
    variables, the working directory, and files you create all carry over. The \
    filesystem is virtual and starts essentially empty; the network is disabled.#{python} \
    Each call returns stdout, stderr, and an exit code.
    """
  end

  # Execute one tool call and return the string the model should see. `args` is the
  # decoded tool input (string keys, as an LLM emits).
  def run(session, %{"commands" => commands}) do
    case Session.exec(session, commands) do
      {:ok, %Result{} = result} -> format(result)
      {:error, message} -> "tool error: #{message}"
    end
  end

  defp format(%Result{stdout: out, stderr: err, exit_code: code}) do
    [
      out,
      if(err != "", do: "\n[stderr]\n#{err}", else: ""),
      if(code != 0, do: "\n[exit #{code}]", else: "")
    ]
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end
end

# ── A simulated agent turn ──────────────────────────────────────────────────
# Pretend the model issued this sequence of tool calls. They build on each other
# to show what makes a *session* valuable as a tool: state persists between calls.

session = Session.new(python: true)

IO.puts("# tool definition the model receives:")
IO.inspect(%{name: "bash", description: BashTool.description(), input_schema: BashTool.schema()},
  pretty: true
)

IO.puts("\n# system prompt:\n" <> BashTool.system_prompt(python: true))

tool_calls = [
  %{"commands" => "printf 'alpha\\nbeta\\ngamma\\n' > /words.txt; wc -l < /words.txt"},
  %{"commands" => "python3 -c \"from pathlib import Path; print(Path('/words.txt').read_text().upper())\""},
  %{"commands" => "cat /nonexistent"}
]

for {call, i} <- Enum.with_index(tool_calls, 1) do
  IO.puts("\n# ── tool call #{i}: #{inspect(call["commands"])}")
  IO.puts("# → tool result the model sees:")
  IO.puts(BashTool.run(session, call))
end

# ── Wiring to ReqLLM (https://hex.pm/packages/req_llm) ──────────────────────
# Add {:req_llm, "~> ..."} to your deps, then build the tool from the same data:
#
#     {:ok, tool} =
#       ReqLLM.Tool.new(
#         name: "bash",
#         description: BashTool.description(),
#         parameter_schema: [
#           commands: [type: :string, required: true, doc: "Bash commands to execute"]
#         ],
#         callback: fn args -> {:ok, BashTool.run(session, args)} end
#       )
#
#     ReqLLM.generate_text(model, messages, tools: [tool])
#
# The same `BashTool.run/2` plugs into LangChain, a raw Anthropic/OpenAI tool
# loop, or any framework — they all just need (args -> result string).

IO.puts("\n# (see the bottom of this file for the ReqLLM wiring snippet)")
