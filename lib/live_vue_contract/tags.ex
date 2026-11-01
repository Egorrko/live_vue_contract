defmodule LiveVueContract.Tags do
  @moduledoc """
  Compile-time check of `<.vue>` tags: walks a compiled HEEx template and compares the attributes
  of every literal `<.vue v-component="X" ...>` (and `<.X>` shortcut) with the schema of `X`.

  The walk matches the call HEEx compiles a function component to,
  `Phoenix.LiveView.TagEngine.component(&fun/1, attrs, caller)`. That form belongs to Phoenix
  LiveView, not to its public API. If a LiveView release changes it, the walk would find nothing
  and every template would pass unchecked; so the tags are also counted in the template source,
  and a template with more `<.vue>` tags than the walk found is a `CompileError`.
  """

  alias LiveVueContract.Schema

  @doc """
  Checks the compiled template `ast`. Options: `:file`, `:line` (where the template starts),
  `:source` (template text; `nil` skips the count), `:shortcuts` (names of `<.X>` shortcut tags).
  """
  def check!(ast, opts) do
    shortcuts = Keyword.get(opts, :shortcuts, [])
    {_ast, tags} = Macro.prewalk(ast, [], &collect(&1, &2, shortcuts))
    tags = Enum.reverse(tags)

    if Schema.all() != %{} do
      for {:literal, name, kw, line} <- tags, do: check_tag!(name, kw, opts, line)
      count!(opts[:source], length(tags), shortcuts, opts)
    end

    :ok
  end

  # {:literal, name, attribute keyword, line}: literal attributes and a literal v-component
  # :dynamic: `{@rest}` or `v-component={@name}`; checked at render time only
  defp collect(
         {{:., _, [_, :component]}, meta, [{:&, _, [{:/, _, [{fun, _, ctx}, 1]}]}, attrs, _]} =
           node,
         acc,
         shortcuts
       )
       when is_atom(fun) and is_atom(ctx) do
    acc =
      cond do
        fun == :vue -> [tag(attrs, Keyword.get(literal_kw(attrs), :"v-component"), meta) | acc]
        Atom.to_string(fun) in shortcuts -> [tag(attrs, Atom.to_string(fun), meta) | acc]
        true -> acc
      end

    {node, acc}
  end

  defp collect(node, acc, _shortcuts), do: {node, acc}

  defp literal_kw({:%{}, _meta, kw}) when is_list(kw), do: kw
  defp literal_kw(_attrs), do: []

  # the line is on the call (.heex files) or on the attribute map (~H)
  defp tag({:%{}, map_meta, kw}, name, meta) when is_list(kw) and is_binary(name),
    do: {:literal, name, kw, meta[:line] || map_meta[:line]}

  defp tag(_attrs, _name, _meta), do: :dynamic

  defp check_tag!(name, kw, opts, line) do
    problems =
      case Schema.fetch(name) do
        {:ok, schema} ->
          case Schema.check_keys(schema, Keyword.keys(kw)) do
            [] -> nil
            problems -> "<.vue v-component=#{inspect(name)}>: " <> Enum.join(problems, "; ")
          end

        :error ->
          "unknown Vue component #{inspect(name)} (not in #{Schema.path()})"

        {:ambiguous, keys} ->
          "Vue component #{inspect(name)} is ambiguous: #{Enum.join(keys, ", ")}"
      end

    if problems,
      do: raise(CompileError, file: opts[:file], line: line || opts[:line], description: problems)
  end

  defp count!(nil, _found, _shortcuts, _opts), do: :ok

  defp count!(source, found, shortcuts, opts) do
    expected = source |> strip_comments() |> count_tags(shortcuts)

    if found < expected do
      raise CompileError,
        file: opts[:file],
        line: opts[:line],
        description: """
        live_vue_contract found #{expected} <.vue> tag(s) in this template but #{found} in the \
        compiled HEEx, so the rest would go unchecked. The compiled form of function components \
        in this Phoenix LiveView version (#{Application.spec(:phoenix_live_view, :vsn)}) is not \
        the one live_vue_contract #{Application.spec(:live_vue_contract, :vsn)} knows. \
        Please report it at https://github.com/Egorrko/live_vue_contract/issues.\
        """
    end

    :ok
  end

  defp strip_comments(source) do
    source
    |> String.replace(~r/<%!--.*?--%>/s, "")
    |> String.replace(~r/<!--.*?-->/s, "")
  end

  defp count_tags(source, shortcuts) do
    names = ["vue" | shortcuts] |> Enum.map(&Regex.escape/1) |> Enum.join("|")
    ~r/<\.(?:#{names})(?=[\s\/>])/ |> Regex.scan(source) |> length()
  end
end
