defmodule LiveVueContract do
  @moduledoc """
  Makes the props contract between `<.vue>` and `defineProps<T>()` red before production.

  The single source of truth is the Vue component's `defineProps<T>()`. A Mix compiler turns
  every `.vue` file into `assets/vue/contract.json` (one JSON-Schema subset per component,
  regenerated whenever a `.vue`/`.ts` source changes); this module checks the Elixir side
  against it twice:

    * at compile time, in `~H`: every literal `<.vue v-component="X" ...>` (and every
      `<.X>` shortcut) must pass exactly the props `X` declares — missing required prop,
      undeclared prop, unknown or ambiguous component name are `CompileError`s;
    * at render time (dev and test), in `vue/1`: the encoded props must match the nested
      schema — renamed key inside a list item, string instead of number, unexpected `null`
      raise `ArgumentError` with the JSON path. Off in `prod`.

  ## Setup

      # mix.exs
      {:live_vue_contract, github: "Egorrko/live_vue_contract"},
      compilers: [:live_vue_contract, :phoenix_live_view] ++ Mix.compilers()

      # lib/my_app_web.ex, in html_helpers, replacing `use LiveVue` and `use LiveVue.Components`
      use LiveVueContract

      $ npm install -D vue-component-meta

  Then `mix compile` writes `assets/vue/contract.json` — commit it, so CI and Docker builds
  without `node` still get the compile-time check.

  ## Options

    * `shared_props: true` — compile templates through `LiveVue.SharedPropsView` (injects
      `v-socket` and `config :live_vue, :shared_props`) instead of the plain `~H`.
    * `shortcuts: false` — do not define `<.ComponentName>` functions.

  ## Config

      config :live_vue_contract,
        vue_root: ["assets/vue"],             # where the components live (like LiveVue.Components)
        watch: [],                            # extra globs that regenerate the contract (prop types are tracked)
        contract: "assets/vue/contract.json",
        tsconfig: "tsconfig.json",
        validate: Mix.env() != :prod,         # render-time validation; :warn = log instead of raise
        strict: false                         # extra nested keys: warning (false) or error (true)
  """

  alias LiveVueContract.Schema

  defmacro __using__(opts) do
    names = if Keyword.get(opts, :shortcuts, true), do: Schema.shortcut_names(), else: []
    Module.put_attribute(__CALLER__.module, :live_vue_shortcuts, names)

    Module.put_attribute(
      __CALLER__.module,
      :live_vue_contract_shared_props,
      Keyword.get(opts, :shared_props, false)
    )

    shortcuts =
      for name <- names do
        quote do
          def unquote(:"#{name}")(assigns) do
            LiveVueContract.vue(Map.put(assigns, :"v-component", unquote(name)))
          end
        end
      end

    quote do
      require LiveVue.SharedPropsView
      import Phoenix.Component, except: [sigil_H: 2]
      import LiveVue, except: [vue: 1]
      import LiveVueContract, only: [sigil_H: 2, vue: 1]

      def __live_vue_shortcuts__, do: unquote(names)

      unquote_splicing(shortcuts)
    end
  end

  @doc "`~H` that compiles as usual and then checks every `<.vue>` tag against the contract."
  defmacro sigil_H(template, modifiers) do
    caller = __CALLER__
    Module.put_attribute(caller.module, :external_resource, Path.expand(Schema.path()))

    base =
      if Module.get_attribute(caller.module, :live_vue_contract_shared_props),
        do: LiveVue.SharedPropsView,
        else: Phoenix.Component

    call = quote(do: unquote(base).sigil_H(unquote(template), unquote(modifiers)))
    ast = Macro.expand_once(call, caller)

    if ast == call,
      do:
        raise(CompileError,
          file: caller.file,
          line: caller.line,
          description: "could not expand ~H"
        )

    check_tags!(ast, caller)
    ast
  end

  @doc "Drop-in for `LiveVue.vue/1` that validates the props against the contract first."
  def vue(assigns) do
    if validate?(), do: validate!(assigns)
    LiveVue.vue(assigns)
  end

  # Deps compile with Mix.env() == :prod, so the default is decided at runtime: under Mix
  # (mix phx.server, mix test) in a non-prod env — validate; in a release there is no Mix — don't.
  defp validate? do
    Application.get_env(
      :live_vue_contract,
      :validate,
      function_exported?(Mix, :env, 0) and Mix.env() != :prod
    )
  end

  @doc false
  def validate!(%{"v-component": name} = assigns) when is_binary(name) do
    case Schema.fetch(name) do
      {:ok, schema} ->
        {props, streams} = props(assigns)

        schema
        |> Map.update("required", [], &(&1 -- streams))
        |> Schema.validate(LiveVue.Encoder.encode(props))
        |> report!(name)

      :error ->
        if Schema.all() != %{},
          do:
            raise(
              ArgumentError,
              "unknown Vue component #{inspect(name)} (not in #{Schema.path()})"
            )

      {:ambiguous, keys} ->
        raise ArgumentError,
              "Vue component #{inspect(name)} is ambiguous: #{Enum.join(keys, ", ")}"
    end

    :ok
  end

  def validate!(_assigns), do: :ok

  defp report!(problems, name) do
    strict? = Application.get_env(:live_vue_contract, :strict, false)
    warn_only? = Application.get_env(:live_vue_contract, :validate) == :warn

    {errors, warnings} =
      Enum.split_with(problems, fn {sev, _, _} ->
        not warn_only? and (sev == :error or strict?)
      end)

    for {_sev, path, msg} <- warnings, warn_once?({name, path}) do
      require Logger

      Logger.warning(
        "<.vue v-component=#{inspect(name)}> sends #{path}: #{msg} (defineProps in #{name}.vue)"
      )
    end

    if errors != [] do
      raise ArgumentError, """
      props of <.vue v-component=#{inspect(name)}> do not match defineProps in #{name}.vue:

      #{Enum.map_join(errors, "\n", fn {_sev, path, msg} -> "  #{path}: #{msg}" end)}
      """
    end
  end

  defp warn_once?({name, path}) do
    # array paths differ only by index; collapse them so one warning per key, not per row
    key = {name, Regex.replace(~r"/\d+(/|$)", path, "/N\\1")}

    if :persistent_term.get({__MODULE__, key}, false) do
      false
    else
      :persistent_term.put({__MODULE__, key}, true)
      true
    end
  end

  # `{props to validate, names of props passed as LiveStreams}`: a stream is a delta, not the
  # value the TS type describes, so it is skipped rather than reported as missing.
  defp props(assigns) do
    keys = assigns |> Map.keys() |> Schema.prop_keys()

    {streams, values} =
      assigns
      |> Enum.filter(fn {k, v} -> to_string(k) in keys and not match?([%{__slot__: _}], v) end)
      |> Enum.split_with(fn {_k, v} -> is_struct(v, Phoenix.LiveView.LiveStream) end)

    {Map.new(values), Enum.map(streams, fn {k, _} -> to_string(k) end)}
  end

  # --- compile time ---------------------------------------------------------

  defp check_tags!(ast, caller) do
    shortcuts = Module.get_attribute(caller.module, :live_vue_shortcuts) || []

    Macro.prewalk(ast, fn
      {{:., _, [_, :component]}, _, [{:&, _, [{:/, _, [{fun, _, ctx}, 1]}]}, {:%{}, meta, kw}, _]} =
          node
      when is_atom(fun) and is_atom(ctx) ->
        line = Keyword.get(meta, :line, caller.line)

        case tag_name(fun, kw, shortcuts) do
          nil -> :skip
          name -> check_tag!(name, kw, caller, line)
        end

        node

      node ->
        node
    end)
  end

  defp tag_name(:vue, kw, _shortcuts) when is_list(kw) do
    case Keyword.get(kw, :"v-component") do
      name when is_binary(name) -> name
      _ -> nil
    end
  end

  defp tag_name(fun, kw, shortcuts) when is_list(kw) do
    name = Atom.to_string(fun)
    if name in shortcuts, do: name
  end

  defp tag_name(_fun, _dynamic_map, _shortcuts), do: nil

  defp check_tag!(name, kw, caller, line) do
    if Schema.all() != %{} do
      case Schema.fetch(name) do
        {:ok, schema} ->
          case Schema.check_keys(schema, Keyword.keys(kw)) do
            [] ->
              :ok

            problems ->
              compile_error!(
                caller,
                line,
                "<.vue v-component=#{inspect(name)}>: " <> Enum.join(problems, "; ")
              )
          end

        :error ->
          compile_error!(
            caller,
            line,
            "unknown Vue component #{inspect(name)} (not in #{Schema.path()})"
          )

        {:ambiguous, keys} ->
          compile_error!(
            caller,
            line,
            "Vue component #{inspect(name)} is ambiguous: #{Enum.join(keys, ", ")}"
          )
      end
    end
  end

  defp compile_error!(caller, line, description) do
    raise CompileError, file: caller.file, line: line, description: description
  end
end
