defmodule ExBashkit.Native do
  @moduledoc false

  # RustlerPrecompiled downloads a prebuilt NIF for the user's target from the
  # matching GitHub release. Local development / CI forces a from-source build
  # with EXBASHKIT_BUILD=1 (see README "Development").
  #
  # IMPORTANT release ordering (learned the hard way on ExMonty): the precompiled
  # download is verified against `checksum-Elixir.ExBashkit.Native.exs`. That file
  # is regenerated AFTER the release workflow uploads the NIF artifacts, via
  #   mix rustler_precompiled.download ExBashkit.Native --all --print
  # and must be committed before `mix hex.publish`. See UPDATE_PROCEDURE.md.

  @version Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :ex_bashkit,
    crate: "ex_bashkit",
    base_url: "https://github.com/jtippett/ex_bashkit/releases/download/v#{@version}",
    version: @version,
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
      aarch64-unknown-linux-gnu
    ),
    force_build: System.get_env("EXBASHKIT_BUILD") in ["1", "true"]

  # Core — keep these stubs in sync with the #[rustler::nif] fns in
  # native/ex_bashkit/src/lib.rs. Each raises until the NIF library loads.
  def exec(_script), do: :erlang.nif_error(:nif_not_loaded)

  # Sessions (persistent, stateful interpreters held as a resource).
  def session_new(
        _env,
        _cwd,
        _username,
        _hostname,
        _mounts,
        _allowed_mount_paths,
        _limits,
        _network
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def session_exec(_session, _script), do: :erlang.nif_error(:nif_not_loaded)
  def session_read_file(_session, _path), do: :erlang.nif_error(:nif_not_loaded)
  def session_write_file(_session, _path, _content), do: :erlang.nif_error(:nif_not_loaded)
end
