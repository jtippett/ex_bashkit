defmodule ExBashkit.Result do
  @moduledoc """
  The outcome of an `ExBashkit.exec/1` call.

  Mirrors bashkit's `ExecResult`. A non-zero `exit_code` is a normal, successful
  return — the script ran and chose to fail, just like a real shell.

  ## Fields

    * `:stdout` - captured standard output
    * `:stderr` - captured standard error
    * `:exit_code` - the script's exit status (`0` is success)
  """

  @type t :: %__MODULE__{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: integer()
        }

  defstruct stdout: "", stderr: "", exit_code: 0
end
