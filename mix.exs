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
