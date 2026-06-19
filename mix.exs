defmodule ExBashkit.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jtippett/ex_bashkit"

  def project do
    [
      app: :ex_bashkit,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "ExBashkit",
      description:
        "Elixir NIF wrapper for bashkit, a sandboxed virtual bash interpreter written in Rust",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.38", optional: true},
      {:rustler_precompiled, "~> 0.9"},
      ex_monty_dep(),
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # Optional: enables the `python` builtin (`Session.new(python: true)`). Consumers
  # opt in by adding `:ex_monty` to their *own* deps; ExBashkit gates on it at
  # runtime via `Code.ensure_loaded?/1` and compiles fine without it.
  #
  # For our own dev/test we prefer the sibling checkout when present (so the two
  # libraries can be co-developed); otherwise (e.g. CI) we fetch the published
  # release, which ships a precompiled NIF — no Rust build of ex_monty/monty.
  defp ex_monty_dep do
    if File.dir?(Path.expand("../ex_monty", __DIR__)) do
      {:ex_monty, path: "../ex_monty", optional: true}
    else
      {:ex_monty, github: "jtippett/ex_monty", tag: "v0.4.0", optional: true}
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib native/ex_bashkit/Cargo.toml native/ex_bashkit/Cargo.lock native/ex_bashkit/src checksum-Elixir.ExBashkit.Native.exs .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end
end
