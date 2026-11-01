defmodule LiveVueContract.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/Egorrko/live_vue_contract"

  def project do
    [
      app: :live_vue_contract,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
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

  # CI overrides the requirements to test the oldest and the newest supported versions.
  defp deps do
    [
      {:live_vue, requirement("LIVE_VUE_VERSION", "~> 1.2")},
      {:phoenix_live_view, requirement("PHOENIX_LIVE_VIEW_VERSION", "~> 1.1")},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp requirement(var, default) do
    case System.get_env(var) do
      blank when blank in [nil, ""] -> default
      requirement -> requirement
    end
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv/gen.mjs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end
