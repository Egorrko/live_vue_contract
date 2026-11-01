defmodule Mix.Tasks.Compile.LiveVueContract do
  @shortdoc "Regenerates the LiveVue props contract from defineProps when its sources changed"
  @moduledoc """
  Runs `priv/gen.mjs` (node + `vue-component-meta` from the host's `node_modules`) when the
  sources of the contract changed since the last run.

  The sources are the `.vue` files under `:vue_root`, every project file the generator read a prop
  type from (it reports them back), and the optional extra globs in `config :live_vue_contract,
  :watch`. Their hash and list live in a stamp in the Mix manifest directory (`_build/<env>/…`),
  not in the contract: an edit to code no prop type touches does not run node at all.

  The generator rewrites the contract only when the schemas change. Every `~H` module lists the
  contract as an external resource, so a rewrite with equal content would recompile all of them.

  Without a stamp (fresh `_build`) and without `node`, an existing contract is used as is with a
  warning; a missing one is an error.

  Add before the Elixir compiler so `~H` sees a fresh contract:

      compilers: [:live_vue_contract, :phoenix_live_view] ++ Mix.compilers()
  """
  use Mix.Task.Compiler

  alias LiveVueContract.Schema

  @stamp "compile.live_vue_contract"
  @stamp_version 1

  @impl true
  def run(_args) do
    roots = Application.get_env(:live_vue_contract, :vue_root, ["assets/vue"])
    vue_files = roots |> Enum.flat_map(&Path.wildcard("#{&1}/**/*.vue")) |> no_node_modules()

    cond do
      vue_files == [] ->
        {:noop, []}

      fresh?(read_stamp(), vue_files) ->
        {:noop, []}

      true ->
        generate(roots, vue_files)
    end
  end

  @impl true
  def manifests, do: [stamp_path()]

  @impl true
  def clean, do: File.rm(stamp_path())

  defp stamp_path, do: Path.join(Mix.Project.manifest_path(), @stamp)

  defp read_stamp do
    with {:ok, bin} <- File.read(stamp_path()),
         {@stamp_version, hash, deps} <- safe_binary_to_term(bin) do
      {hash, deps}
    else
      _ -> nil
    end
  end

  defp safe_binary_to_term(bin) do
    :erlang.binary_to_term(bin)
  rescue
    ArgumentError -> nil
  end

  defp fresh?(nil, _vue_files), do: false

  defp fresh?({hash, deps}, vue_files),
    do: File.exists?(Schema.path()) and hash(vue_files, deps) == hash

  # Sorted, deduplicated paths with their content; a deleted file hashes as absent.
  defp hash(vue_files, deps) do
    watch = Application.get_env(:live_vue_contract, :watch, [])

    sources =
      (vue_files ++ deps ++ Enum.flat_map(watch, &Path.wildcard/1))
      |> no_node_modules()
      |> Enum.uniq()
      |> Enum.sort()

    # the generator itself is a source: a library upgrade that changes it regenerates the contract
    :crypto.hash(
      :sha256,
      [
        File.read!(script())
        | Enum.map(sources, fn path ->
            case File.read(path) do
              {:ok, content} -> [path, 0, content, 0]
              {:error, _} -> [path, 1]
            end
          end)
      ]
    )
  end

  defp script, do: Path.join(:code.priv_dir(:live_vue_contract), "gen.mjs")

  defp no_node_modules(paths), do: Enum.reject(paths, &String.contains?(&1, "node_modules"))

  defp generate(roots, vue_files) do
    out = Schema.path()
    node = System.find_executable("node")

    cond do
      node && File.dir?("node_modules/vue-component-meta") ->
        run_generator(node, roots, vue_files, out)

      File.exists?(out) and read_stamp() == nil ->
        Mix.shell().info(
          "live_vue_contract: no node or vue-component-meta, using #{out} as is (freshness not checked)"
        )

        {:noop, []}

      true ->
        Mix.raise("""
        live_vue_contract: #{out} is #{if File.exists?(out), do: "stale", else: "missing"} and cannot be regenerated:
        #{if node, do: "vue-component-meta is not installed — run `npm install -D vue-component-meta`", else: "node is not on PATH"}.
        Regenerate it with `mix compile` where node is available.
        """)
    end
  end

  defp run_generator(node, roots, vue_files, out) do
    script = script()
    tsconfig = Application.get_env(:live_vue_contract, :tsconfig, "tsconfig.json")
    File.mkdir_p!(Mix.Project.manifest_path())
    deps_file = stamp_path() <> ".deps.json"

    case System.cmd(node, [script, tsconfig, out, deps_file | roots], stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(String.trim(output))
        deps = deps_file |> File.read!() |> JSON.decode!()
        File.rm(deps_file)
        stamp = {@stamp_version, hash(vue_files, deps), deps}
        File.write!(stamp_path(), :erlang.term_to_binary(stamp))
        {:ok, []}

      {output, status} ->
        Mix.raise("live_vue_contract: generator failed (#{status}):\n#{output}")
    end
  end
end
