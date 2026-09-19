defmodule LiveVueContract.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/Egorrko/live_vue_contract"

  def project do
    [
      app: :live_vue_contract,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Props contract between <.vue> and defineProps<T>() for LiveVue: drift is red on mix compile / mix test",
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [{:live_vue, "~> 1.2"}]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end
