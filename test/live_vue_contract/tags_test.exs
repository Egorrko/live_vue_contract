defmodule LiveVueContract.TagsTest.Resources do
  # registered after `use LiveVueContract`, so it runs after its @before_compile
  defmacro __before_compile__(env) do
    resources = Module.get_attribute(env.module, :external_resource)
    quote(do: def(resources, do: unquote(resources)))
  end
end

defmodule LiveVueContract.TagsTest do
  # Compiles real templates through `use LiveVueContract` / the .heex engine against a small
  # contract: if Phoenix LiveView changes what HEEx compiles to, these fail instead of the
  # check going quiet.
  use ExUnit.Case, async: false

  alias LiveVueContract.Tags

  @contract %{
    "HomePage" => %{
      "type" => "object",
      "properties" => %{"title" => %{"type" => "string"}, "count" => %{"type" => "number"}},
      "required" => ["title"]
    },
    "admin/Panel" => %{"type" => "object", "properties" => %{}, "required" => []}
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "lvc_tags_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "contract.json")
    File.write!(path, JSON.encode!(@contract))
    Application.put_env(:live_vue_contract, :contract, path)

    on_exit(fn ->
      Application.delete_env(:live_vue_contract, :contract)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp compile(template, opts \\ "") do
    mod = :"Elixir.LiveVueContract.TagsTest.M#{System.unique_integer([:positive])}"
    body = template |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))

    Code.compile_string("""
    defmodule #{inspect(mod)} do
      use Phoenix.Component
      use LiveVueContract#{opts}

      def render(assigns) do
        ~H\"\"\"
    #{body}
        \"\"\"
      end
    end
    """)

    mod
  end

  defp compile_error(template, opts \\ "") do
    assert_raise CompileError, fn -> compile(template, opts) end
  end

  test "matching tag compiles" do
    assert compile(~S|<.vue v-component="HomePage" title="x" count={1} id="home" />|)
  end

  test "shared_props: true compiles through LiveVue.SharedPropsView and still checks" do
    assert compile(~S|<.vue v-component="HomePage" title="x" />|, ", shared_props: true")

    assert compile_error(~S|<.vue v-component="HomePage" />|, ", shared_props: true").description =~
             "missing required prop"
  end

  test "missing required prop" do
    e = compile_error(~S|<div><.vue v-component="HomePage" count={1} /></div>|)
    assert e.description =~ ~s(<.vue v-component="HomePage">: missing required prop "title")
    # the template starts on line 7 of the generated module
    assert e.line == 7
  end

  test "prop not declared in defineProps" do
    e = compile_error(~S|<.vue v-component="HomePage" title="x" total={2} />|)
    assert e.description =~ ~s(prop "total" is not declared in defineProps)
  end

  test "unknown and ambiguous components" do
    assert compile_error(~S|<.vue v-component="HomePag" title="x" />|).description =~
             ~s(unknown Vue component "HomePag")

    assert compile(~S|<.vue v-component="Panel" />|)
  end

  test "tags inside :for, :if and slots are checked" do
    e =
      compile_error(~S"""
      <div :for={i <- [1]}>
        <.vue :if={i > 0} v-component="HomePage" count={i} />
      </div>
      """)

    assert e.description =~ "missing required prop"
  end

  test "<.Shortcut> tags are checked" do
    assert compile(~S|<.HomePage title="x" />|)
    assert compile_error(~S|<.HomePage />|).description =~ "missing required prop"
  end

  test "dynamic attributes and names are left to render time" do
    assert compile(~S|<.vue v-component="HomePage" {@rest} />|)
    assert compile(~S|<.vue v-component={@name} />|)
  end

  test "commented-out tags are not counted" do
    assert compile(~S"""
           <%!-- <.vue v-component="HomePage" /> --%>
           <!-- <.vue v-component="HomePage" /> -->
           <.vue v-component="HomePage" title="x" />
           """)
  end

  test "a tag the walk cannot find is a CompileError, not a silent pass" do
    e =
      assert_raise CompileError, fn ->
        Tags.check!(quote(do: :not_a_component_call),
          source: ~S|<.vue v-component="HomePage" />|,
          file: "x.ex",
          line: 1
        )
      end

    assert e.description =~ "found 1 <.vue> tag(s) in this template but 0 in the compiled HEEx"
  end

  describe ".heex files" do
    # `embed_templates` in a module with `use LiveVueContract`
    defp compile_embedded(dir, opts \\ "") do
      mod = :"Elixir.LiveVueContract.TagsTest.E#{System.unique_integer([:positive])}"

      Code.compile_string("""
      defmodule #{inspect(mod)} do
        use Phoenix.Component
        use LiveVueContract#{opts}
        embed_templates "*", root: #{inspect(dir)}
        @before_compile LiveVueContract.TagsTest.Resources
      end
      """)

      mod
    end

    defp heex_dir(dir, files) do
      sub = Path.join(dir, "t#{System.unique_integer([:positive])}")
      File.mkdir_p!(sub)
      for {name, body} <- files, do: File.write!(Path.join(sub, name), body)
      sub
    end

    test "checks <.vue> and <.Shortcut> in embedded templates", %{dir: dir} do
      ok =
        heex_dir(dir, %{
          "page.html.heex" =>
            ~S|<.vue v-component="HomePage" title="x" /><.HomePage title="y" />| <> "\n",
          "plain.html.heex" => "<p>no vue here</p>\n"
        })

      mod = compile_embedded(ok)
      assert Path.expand(Application.get_env(:live_vue_contract, :contract)) in mod.resources()

      bad =
        heex_dir(dir, %{
          "bad.html.heex" => "<p>hi</p>\n" <> ~S|<.vue v-component="HomePage" />| <> "\n"
        })

      e = assert_raise CompileError, fn -> compile_embedded(bad) end
      assert e.description =~ "missing required prop"
      assert e.file == Path.join(bad, "bad.html.heex")
      assert e.line == 2

      short = heex_dir(dir, %{"short.html.heex" => ~S|<.HomePage count={1} />| <> "\n"})
      assert_raise CompileError, ~r/missing required prop/, fn -> compile_embedded(short) end
    end

    test "checks the colocated template of a LiveView", %{dir: dir} do
      n = System.unique_integer([:positive])
      file = Path.join(dir, "l#{n}.ex")

      File.write!(
        Path.join(dir, "l#{n}.html.heex"),
        ~S|<.vue v-component="HomePage" count={1} />| <> "\n"
      )

      e =
        assert_raise CompileError, fn ->
          Code.compile_string(
            """
            defmodule LiveVueContract.TagsTest.L#{n} do
              use Phoenix.LiveView
              use LiveVueContract
            end
            """,
            file
          )
        end

      assert e.description =~ "missing required prop"
    end

    test "modules without use LiveVueContract are not touched", %{dir: dir} do
      bad = heex_dir(dir, %{"bad.html.heex" => ~S|<.vue v-component="HomePage" />| <> "\n"})
      mod = :"Elixir.LiveVueContract.TagsTest.P#{System.unique_integer([:positive])}"

      Code.compile_string("""
      defmodule #{inspect(mod)} do
        use Phoenix.Component
        def vue(assigns), do: ~H""
        embed_templates "*", root: #{inspect(bad)}
      end
      """)
    end
  end

  test "render-time check raises with the JSON path" do
    e =
      assert_raise ArgumentError, fn ->
        LiveVueContract.validate!(%{"v-component": "HomePage", title: 1, count: 2})
      end

    assert e.message =~ "/title: expected string, got 1"
  end
end
