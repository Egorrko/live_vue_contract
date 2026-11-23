defmodule LiveVueContract.Coverage do
  @moduledoc """
  What the render-time checks never saw in a test run.

  The nested checks of props and events run on the data a test renders and the events it
  pushes; a component no test renders is checked only at compile time, an event no test pushes is
  not checked at all. Start this in `test/test_helper.exs`:

      LiveVueContract.Coverage.start()
      ExUnit.start()

  and the suite ends with a report:

      live_vue_contract: 17 of 19 <.vue> components rendered, 40 of 52 events pushed
        never rendered: AdminPanel (lib/my_app_web/live/admin_live.ex), ...
        never pushed: join (assets/vue/WorldPage.vue), ...

  Components count when a template in the app has a literal `<.vue v-component="X">` or `<.X>`
  for them; events count when a component declares them with `useLiveEvents`.

  Option `:app` — the OTP app whose modules hold the templates (default: the current Mix project).

  ## Partitioned runs

  Under `mix test --partitions N` (`MIX_TEST_PARTITION` is set) every partition sees only its
  own tests, so instead of printing a partial report each one adds what it saw to
  `_build/live_vue_contract_coverage/<partition>.etf`. After the last partition,
  `mix live_vue_contract.coverage` merges the files, prints one report and deletes them.
  Option `:export` names the file explicitly (`export: "unit"`) for other ways of splitting a run.
  """

  alias LiveVueContract.Schema

  @flag {__MODULE__, :on}

  @doc "Starts recording and prints the report (or exports it, see above) after the suite."
  def start(opts \\ []) do
    :persistent_term.put(@flag, true)
    app = Keyword.get_lazy(opts, :app, fn -> Mix.Project.config()[:app] end)

    export =
      Keyword.get_lazy(opts, :export, fn ->
        case System.get_env("MIX_TEST_PARTITION", "") do
          "" -> nil
          n -> "partition_" <> n
        end
      end)

    ExUnit.after_suite(fn _result ->
      if export do
        path = export(export)

        IO.puts(
          "live_vue_contract: coverage written to #{Path.relative_to_cwd(path)}, " <>
            "mix live_vue_contract.coverage merges the partitions"
        )
      else
        app |> report() |> format() |> IO.puts()
      end
    end)

    :ok
  end

  @doc false
  def dir, do: Path.join(Path.dirname(Mix.Project.build_path()), "live_vue_contract_coverage")

  @doc """
  Adds what this run saw to `<dir>/<name>.etf` (a union with an earlier run under the same name,
  e.g. a partition retried on its failures) and returns the path.
  """
  def export(name) do
    path = Path.join(dir(), name <> ".etf")
    File.mkdir_p!(dir())
    write_seen(path, MapSet.union(read_seen(path), seen()))
    path
  end

  @doc """
  Merges the exported files: `{report, files}`. `files` is empty when nothing was exported.
  """
  def merge(app) do
    files = Path.wildcard(Path.join(dir(), "*.etf"))
    all = Enum.reduce(files, MapSet.new(), &MapSet.union(read_seen(&1), &2))
    {report(app, &MapSet.member?(all, {&1, &2})), files}
  end

  defp seen do
    for {{__MODULE__, kind, key}, true} <- :persistent_term.get(),
        into: MapSet.new(),
        do: {kind, key}
  end

  defp read_seen(path) do
    case File.read(path) do
      {:ok, bin} -> :erlang.binary_to_term(bin)
      {:error, :enoent} -> MapSet.new()
    end
  end

  defp write_seen(path, set), do: File.write!(path, :erlang.term_to_binary(set))

  @doc false
  def record(kind, key) do
    if :persistent_term.get(@flag, false) do
      term = {__MODULE__, kind, key}
      unless :persistent_term.get(term, false), do: :persistent_term.put(term, true)
    end

    :ok
  end

  @doc false
  def seen?(kind, key), do: :persistent_term.get({__MODULE__, kind, key}, false)

  @doc """
  `%{components: [{key, [module]}], unrendered: [...], events: [name], unpushed: [{name, [file]}]}`.
  """
  def report(app, seen? \\ &seen?/2) do
    tags =
      for module <- modules(app),
          function_exported?(module, :__live_vue_tags__, 0),
          name <- module.__live_vue_tags__(),
          {:ok, key, _schema} <- [Schema.resolve(name)],
          reduce: %{} do
        acc -> Map.update(acc, key, [module], &Enum.uniq([module | &1]))
      end

    components = tags |> Enum.sort()
    unrendered = Enum.reject(components, fn {key, _} -> seen?.(:component, key) end)

    events =
      Schema.events()
      |> Enum.map(fn {name, variants} ->
        {name, variants |> Enum.flat_map(& &1["declared"]) |> Enum.uniq()}
      end)
      |> Enum.sort()

    unpushed = Enum.reject(events, fn {name, _} -> seen?.(:event, name) end)

    %{components: components, unrendered: unrendered, events: events, unpushed: unpushed}
  end

  @doc false
  def format(%{components: c, unrendered: ur, events: e, unpushed: up}) do
    head =
      "live_vue_contract: #{length(c) - length(ur)} of #{length(c)} <.vue> components rendered, " <>
        "#{length(e) - length(up)} of #{length(e)} events pushed"

    lines =
      Enum.map(ur, fn {key, mods} ->
        "  never rendered: #{key} (#{Enum.map_join(mods, ", ", &source/1)})"
      end) ++
        Enum.map(up, fn {name, files} -> "  never pushed: #{name} (#{Enum.join(files, ", ")})" end)

    Enum.join([head | lines], "\n")
  end

  defp source(module) do
    case module.module_info(:compile)[:source] do
      nil -> inspect(module)
      path -> path |> List.to_string() |> Path.relative_to_cwd()
    end
  end

  defp modules(app) do
    Application.load(app)
    Application.spec(app, :modules) || []
  end
end
