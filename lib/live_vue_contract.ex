defmodule LiveVueContract do
  @moduledoc """
  Makes the props contract between `<.vue>` and `defineProps<T>()` red before production.

  The single source of truth is the Vue component's `defineProps<T>()`. A Mix compiler turns
  every `.vue` file into `assets/vue/contract.json` (one JSON-Schema subset per component,
  regenerated whenever a `.vue`/`.ts` source changes); this module checks the Elixir side
  against it twice:

    * at compile time, in `~H` and in the module's `.heex` files: every literal
      `<.vue v-component="X" ...>` (and every `<.X>` shortcut) must pass exactly the props `X`
      declares — missing required prop, undeclared prop, unknown or ambiguous component name are
      `CompileError`s;
    * at render time (dev and test), in `vue/1`: the encoded props must match the nested
      schema — renamed key inside a list item, string instead of number, unexpected `null`
      raise `ArgumentError` with the JSON path. Off in `prod`.

  ## Setup

      # mix.exs
      {:live_vue_contract, "~> 0.3"},
      compilers: [:live_vue_contract, :phoenix_live_view] ++ Mix.compilers()

      # lib/my_app_web.ex, in html_helpers, replacing `use LiveVue` and `use LiveVue.Components`
      use LiveVueContract

      $ npm install -D vue-component-meta typescript

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

    Module.register_attribute(__CALLER__.module, :live_vue_contract_tags, accumulate: true)

    shortcuts =
      for name <- names do
        quote do
          def unquote(:"#{name}")(assigns) do
            LiveVueContract.vue(Map.put(assigns, :"v-component", unquote(name)))
          end
        end
      end

    quote do
      @before_compile LiveVueContract
      require LiveVue.SharedPropsView
      import Phoenix.Component, except: [sigil_H: 2]
      import LiveVue, except: [vue: 1]
      import LiveVueContract, only: [sigil_H: 2, vue: 1]

      def __live_vue_shortcuts__, do: unquote(names)

      unquote_splicing(shortcuts)
    end
  end

  # `.heex` files of the module: `embed_templates` lists them as external resources, a LiveView's
  # colocated template (`page_live.html.heex` next to `page_live.ex`) is found by name, like
  # Phoenix.LiveView.Renderer does. Each file with a `<.vue>` tag is compiled once more, only for
  # the check; the module keeps the code Phoenix compiled. This is done here and not with a
  # template engine in `config :phoenix, :template_engines`: that config also applies to
  # dependencies, which compile before live_vue_contract does.
  @doc false
  defmacro __before_compile__(env) do
    shortcuts = Module.get_attribute(env.module, :live_vue_shortcuts) || []
    colocated = Path.join(Path.dirname(env.file), template_name(env.module) <> ".heex")

    files =
      (List.wrap(Module.get_attribute(env.module, :external_resource)) ++ [colocated])
      |> Enum.filter(&String.ends_with?(&1, ".heex"))
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()
      |> Enum.filter(&File.regular?/1)

    heex_tags =
      for path <- files,
          source = File.read!(path),
          LiveVueContract.Tags.mentions?(source, shortcuts),
          name <- check_heex!(path, source, env, shortcuts),
          do: name

    tags =
      (heex_tags ++ List.wrap(Module.get_attribute(env.module, :live_vue_contract_tags)))
      |> Enum.uniq()
      |> Enum.sort()

    quote do
      @doc false
      def __live_vue_tags__, do: unquote(tags)

      unquote(wrap_handle_event(env))
    end
  end

  # handle_event/3 of a LiveView or LiveComponent, wrapped to check events declared with
  # `useLiveEvents` (LiveVueContract.Events). Not compiled in when validation is off at compile
  # time, so a release pays nothing.
  defp wrap_handle_event(env) do
    behaviours = List.wrap(Module.get_attribute(env.module, :behaviour))

    if validate?() and Module.defines?(env.module, {:handle_event, 3}, :def) and
         Enum.any?(behaviours, &(&1 in [Phoenix.LiveView, Phoenix.LiveComponent])) do
      quote do
        defoverridable handle_event: 3

        def handle_event(event, params, socket) do
          LiveVueContract.Events.handle(__MODULE__, event, params, fn ->
            super(event, params, socket)
          end)
        end
      end
    end
  end

  defp template_name(module),
    do: module |> Module.split() |> List.last() |> Macro.underscore() |> Kernel.<>(".html")

  defp check_heex!(path, source, env, shortcuts) do
    Module.put_attribute(env.module, :external_resource, Path.expand(Schema.path()))
    {:ok, env} = Macro.Env.define_require(env, [], Phoenix.LiveView.HTMLEngine)
    call = quote(do: Phoenix.LiveView.HTMLEngine.compile(unquote(path)))
    ast = Macro.expand_once(call, env)

    if ast == call,
      do:
        raise(CompileError,
          file: path,
          description: "live_vue_contract: could not expand #{path}"
        )

    LiveVueContract.Tags.check!(ast, source: source, file: path, line: 1, shortcuts: shortcuts)
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

    names =
      LiveVueContract.Tags.check!(ast,
        source: template_source(template),
        file: caller.file,
        line: caller.line,
        shortcuts: Module.get_attribute(caller.module, :live_vue_shortcuts) || []
      )

    for name <- names, do: Module.put_attribute(caller.module, :live_vue_contract_tags, name)

    ast
  end

  defp template_source({:<<>>, _meta, [source]}) when is_binary(source), do: source
  defp template_source(_template), do: nil

  @doc "Drop-in for `LiveVue.vue/1` that validates the props against the contract first."
  def vue(assigns) do
    if validate?(), do: validate!(assigns)
    LiveVue.vue(assigns)
  end

  # Deps compile with Mix.env() == :prod, so the default is decided at runtime: under Mix
  # (mix phx.server, mix test) in a non-prod env — validate; in a release there is no Mix — don't.
  # true / :warn -> validate (raising or logging), false -> off
  defp validate? do
    Application.get_env(
      :live_vue_contract,
      :validate,
      function_exported?(Mix, :env, 0) and Mix.env() != :prod
    ) not in [false, nil]
  end

  @doc false
  def validate!(%{"v-component": name} = assigns) when is_binary(name) do
    case Schema.resolve(name) do
      {:ok, key, schema} ->
        LiveVueContract.Events.rendered(key)
        LiveVueContract.Coverage.record(:component, key)
        {props, streams} = props(assigns)
        {props, skip} = changed(schema, props, assigns)

        schema
        |> Map.update("required", [], &(&1 -- (streams ++ skip)))
        |> Schema.validate(LiveVue.Encoder.encode(props))
        |> LiveVueContract.Report.raise_or_warn!(
          ~s|props of <.vue v-component=#{inspect(name)}>|,
          "defineProps in #{key}.vue"
        )

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

  # `{props to validate, names of required props not to report missing}`. On an update LiveView
  # marks in `__changed__` the attributes whose value may differ from the last render; the others
  # passed the check then and the schema has not changed, so only the changed ones are walked
  # (a dashboard's props take tens of ms, re-checked on each of the dozens of renders that change
  # one tile). A required prop absent now is still reported: it is not in `props` at all. On the
  # first render, and wherever LiveView does not track changes, `__changed__` is nil: all of them.
  defp changed(%{"type" => "object", "properties" => _} = schema, props, assigns)
       when is_map(assigns.__changed__) do
    changed = assigns.__changed__
    {fresh, stale} = props |> Map.keys() |> Enum.split_with(&Map.has_key?(changed, &1))
    stale = Enum.map(stale, &to_string/1)
    {Map.take(props, fresh), Enum.filter(Map.get(schema, "required", []), &(&1 in stale))}
  end

  defp changed(_schema, props, _assigns), do: {props, []}

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
end
