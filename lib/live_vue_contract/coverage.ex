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
  """

  alias LiveVueContract.Schema

  @flag {__MODULE__, :on}

  @doc "Starts recording and prints the report after the suite."
  def start(opts \\ []) do
    :persistent_term.put(@flag, true)
    app = Keyword.get_lazy(opts, :app, fn -> Mix.Project.config()[:app] end)

    ExUnit.after_suite(fn _result -> app |> report() |> format() |> IO.puts() end)

    :ok
  end

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
  def report(app) do
    tags =
      for module <- modules(app),
          function_exported?(module, :__live_vue_tags__, 0),
          name <- module.__live_vue_tags__(),
          {:ok, key, _schema} <- [Schema.resolve(name)],
          reduce: %{} do
        acc -> Map.update(acc, key, [module], &Enum.uniq([module | &1]))
      end

    components = tags |> Enum.sort()
    unrendered = Enum.reject(components, fn {key, _} -> seen?(:component, key) end)

    events =
      Schema.events()
      |> Enum.map(fn {name, variants} ->
        {name, variants |> Enum.flat_map(& &1["declared"]) |> Enum.uniq()}
      end)
      |> Enum.sort()

    unpushed = Enum.reject(events, fn {name, _} -> seen?(:event, name) end)

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
