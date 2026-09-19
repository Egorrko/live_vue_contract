defmodule Mix.Tasks.Compile.LiveVueContract do
  @shortdoc "Regenerates the LiveVue props contract from defineProps when a Vue source changed"
  @moduledoc """
  Runs `priv/gen.mjs` (node + `vue-component-meta` from the host's `node_modules`) whenever
  the hash of the watched sources (`config :live_vue_contract, :watch`, default
  `assets/**/*.{vue,ts}`) differs from the one recorded in the contract file. A committed,
  fresh contract therefore compiles without `node`.

  Add before the Elixir compiler so `~H` sees a fresh contract:

      compilers: [:live_vue_contract, :phoenix_live_view] ++ Mix.compilers()
  """
  use Mix.Task.Compiler

  alias LiveVueContract.Schema

  @impl true
  def run(_args) do
    roots = Application.get_env(:live_vue_contract, :vue_root, ["assets/vue"])
    watch = Application.get_env(:live_vue_contract, :watch, ["assets/**/*.{vue,ts}"])
    vue_files = Enum.flat_map(roots, &Path.wildcard("#{&1}/**/*.vue"))

    sources =
      (vue_files ++ Enum.flat_map(watch, &Path.wildcard/1))
      |> Enum.reject(&String.contains?(&1, "node_modules"))
      |> Enum.uniq()
      |> Enum.sort()

    hash =
      :crypto.hash(:sha256, Enum.map(sources, &[&1, 0, File.read!(&1)]))
      |> Base.encode16(case: :lower)

    cond do
      vue_files == [] -> {:noop, []}
      Schema.sources() == hash -> {:noop, []}
      true -> generate(roots, hash)
    end
  end

  defp generate(roots, hash) do
    out = Schema.path()
    node = System.find_executable("node")

    unless node && File.dir?("node_modules/vue-component-meta") do
      Mix.raise("""
      live_vue_contract: #{out} is #{if File.exists?(out), do: "stale", else: "missing"} and cannot be regenerated:
      #{if node, do: "vue-component-meta is not installed — run `npm install -D vue-component-meta`", else: "node is not on PATH"}.
      Regenerate it with `mix compile` where node is available and commit the file.
      """)
    end

    script = Path.join(:code.priv_dir(:live_vue_contract), "gen.mjs")
    tsconfig = Application.get_env(:live_vue_contract, :tsconfig, "tsconfig.json")

    case System.cmd(node, [script, tsconfig, out, hash | roots], stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(String.trim(output))
        {:ok, []}

      {output, status} ->
        Mix.raise("live_vue_contract: generator failed (#{status}):\n#{output}")
    end
  end
end
