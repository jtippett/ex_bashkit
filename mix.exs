defmodule ExBashkit.MixProject do
  use Mix.Project

  @version "0.1.1"
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
      # `:ex_monty` enables the `python` builtin (`Session.new(python: true)`). It's
      # an *optional* dependency: consumers opt in by adding `:ex_monty` to their
      # own deps, and ExBashkit gates on it at runtime via `Code.ensure_loaded?/1`
      # and compiles cleanly without it. (It ships a precompiled NIF, so enabling
      # python needs no Rust build.)
      {:ex_monty, "~> 0.4", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
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
