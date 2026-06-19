defmodule ExBashkit do
  @moduledoc """
  Run bash scripts in a sandboxed, virtual interpreter — no real processes,
  no host filesystem, no network unless you grant it.

  ExBashkit wraps [bashkit](https://github.com/everruns/bashkit), a pure-Rust
  reimplementation of bash. Scripts execute entirely in-memory: ~150 builtins
  (`echo`, `grep`, `sed`, `awk`, `jq`, `cat`, `find`, …) are reimplemented in
  Rust rather than shelled out, file I/O hits a virtual filesystem, and there is
  no `fork`/`exec` escape hatch. This makes it safe to run untrusted scripts —
  e.g. bash produced by an LLM agent.

  ## Quick start

      iex> ExBashkit.exec("echo hello | tr a-z A-Z")
      {:ok, %ExBashkit.Result{stdout: "HELLO\\n", stderr: "", exit_code: 0}}

  > #### Skeleton {: .warning}
  >
  > This is an early scaffold. Only stateless `exec/1` is wired up. Persistent
  > sessions, virtual-filesystem mounts, resource limits, a network allowlist,
  > and Elixir-defined custom builtins are planned — see `PORTING.md`.
  """

  alias ExBashkit.Result

  @doc """
  Execute a bash `script` in a fresh sandbox and return its result.

  Returns `{:ok, %ExBashkit.Result{}}` on success (note: a non-zero
  `exit_code` is still `{:ok, ...}` — the script ran; it just failed, exactly
  like a real shell). Returns `{:error, message}` if the script could not be
  parsed or the interpreter itself errored.

  Each call runs in an independent sandbox; no state carries across calls.

  ## Examples

      iex> {:ok, result} = ExBashkit.exec("echo hi")
      iex> result.stdout
      "hi\\n"

      iex> {:ok, result} = ExBashkit.exec("false")
      iex> result.exit_code
      1
  """
  @spec exec(String.t()) :: {:ok, Result.t()} | {:error, String.t()}
  def exec(script) when is_binary(script) do
    case ExBashkit.Native.exec(script) do
      {:ok, {stdout, stderr, exit_code}} ->
        {:ok, %Result{stdout: stdout, stderr: stderr, exit_code: exit_code}}

      {:error, message} ->
        {:error, message}
    end
  end
end
