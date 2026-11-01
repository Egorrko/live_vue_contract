defmodule LiveVueContract.HEExEngine do
  @moduledoc """
  Template engine for `.heex` files that compiles them with Phoenix LiveView's engine and then
  checks their `<.vue>` tags like `~H` does. Covers colocated LiveView templates
  (`page_live.html.heex`) and `embed_templates`:

      # config/config.exs
      config :phoenix, :template_engines, heex: LiveVueContract.HEExEngine

  The check runs where the template is expanded, inside the module that renders it: `<.X>`
  shortcuts count when that module has `use LiveVueContract`, and the contract becomes one of
  its external resources, so a changed contract recompiles it.
  """
  @behaviour Phoenix.Template.Engine

  @impl true
  def compile(path, _name) do
    quote do
      require LiveVueContract.HEExEngine
      LiveVueContract.HEExEngine.__compile__(unquote(path))
    end
  end

  # Phoenix.LiveView.HTMLEngine.compile/2 returns a call to its compile/1 macro, which compiles the
  # file when expanded in the caller; it is expanded here so the check sees the compiled template.
  @doc false
  defmacro __compile__(path) do
    caller = __CALLER__
    {:ok, env} = Macro.Env.define_require(caller, [], Phoenix.LiveView.HTMLEngine)
    call = quote(do: Phoenix.LiveView.HTMLEngine.compile(unquote(path)))
    ast = Macro.expand_once(call, env)

    if ast == call,
      do:
        raise(CompileError,
          file: path,
          description: "live_vue_contract: could not expand #{path}"
        )

    Module.put_attribute(
      caller.module,
      :external_resource,
      Path.expand(LiveVueContract.Schema.path())
    )

    LiveVueContract.Tags.check!(ast,
      source: File.read!(path),
      file: path,
      line: 1,
      shortcuts: Module.get_attribute(caller.module, :live_vue_shortcuts) || []
    )

    ast
  end
end
