defmodule LiveVueContract.Schema do
  @moduledoc """
  Reads the generated contract file (JSON-Schema subset per Vue component) and
  validates encoded props against it.

  The file is produced from `defineProps<T>()` by `priv/gen.mjs`; nothing in it is
  written by hand. Keys are paths relative to a `vue_root` without extension
  (`"initiatives/InitiativeList"`, `"prototypes/players/index"`); `fetch/1` resolves a
  `v-component` name the way LiveVue's `findComponent` does — by path suffix, `index`
  ignored — so `"InitiativeList"` and `"prototypes/players"` both work.
  """

  @special ~w(id class v-ssr v-diff v-component v-socket v-inject __changed__ __given__ inner_block)
  @sources "$sources"

  @doc "Path of the contract file, relative to the host app's cwd."
  def path, do: Application.get_env(:live_vue_contract, :contract, "assets/vue/contract.json")

  @doc "All schemas keyed by component name; `%{}` when the file is absent."
  def all do
    path = path()

    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        case :persistent_term.get({__MODULE__, path}, nil) do
          {^mtime, schemas} ->
            schemas

          _ ->
            schemas = path |> File.read!() |> JSON.decode!() |> Map.delete(@sources)
            :persistent_term.put({__MODULE__, path}, {mtime, schemas})
            schemas
        end

      _ ->
        %{}
    end
  end

  @doc "Hash of the sources the contract file was generated from, or `nil`."
  def sources do
    case File.read(path()) do
      {:ok, json} -> json |> JSON.decode!() |> Map.get(@sources)
      _ -> nil
    end
  end

  @doc "Shortcut tag names (`<.ComponentName>`): file basenames, like `LiveVue.Components`."
  def shortcut_names, do: all() |> Map.keys() |> Enum.map(&Path.basename/1) |> Enum.uniq()

  @doc """
  Schema for a `v-component` name: `{:ok, schema}`, `:error`, or `{:ambiguous, keys}`.
  Matches by path suffix with `index` segments ignored, exactly like `findComponent` in LiveVue's JS.
  """
  def fetch(name) do
    parts =
      name
      |> String.replace_suffix(".vue", "")
      |> String.split("/")
      |> Enum.reject(&(&1 == "index"))

    matches =
      for {key, schema} <- all(), suffix?(key_parts(key), parts), do: {key, schema}

    case matches do
      [{_key, schema}] -> {:ok, schema}
      [] -> :error
      many -> {:ambiguous, many |> Enum.map(&elem(&1, 0)) |> Enum.sort()}
    end
  end

  defp key_parts(key) do
    parts = String.split(key, "/")
    if List.last(parts) == "index", do: Enum.drop(parts, -1), else: parts
  end

  defp suffix?(key_parts, parts),
    do: length(parts) <= length(key_parts) and Enum.take(key_parts, -length(parts)) == parts

  @doc "Attribute names of a `<.vue>` tag that LiveVue would send as props."
  def prop_keys(keys) do
    keys
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in @special or String.starts_with?(&1, ["v-on:", "v-inject:"])))
  end

  @doc """
  Compares attribute names with the schema. Returns `[]` or a list of problems.
  `shared` are props injected by `LiveVue.SharedPropsView` (always present on the wire).
  """
  def check_keys(%{"properties" => props} = schema, keys, shared \\ []) do
    keys = prop_keys(keys) ++ Enum.map(shared, &to_string/1)
    required = Map.get(schema, "required", [])
    missing = required -- keys
    extra = keys -- Map.keys(props)

    Enum.map(missing, &"missing required prop #{inspect(&1)}") ++
      Enum.map(extra, &"prop #{inspect(&1)} is not declared in defineProps")
  end

  @doc """
  Validates an encoded (JSON-ready) props map.

  Returns `[]` or `[{severity, path, message}]`. A key the TS type does not declare is
  `:warn` (TypeScript is structural; the client just never reads it), everything else is `:error`.
  """
  def validate(schema, value), do: do_validate(schema, value, "")

  defp do_validate(%{"type" => "any"}, _v, _p), do: []

  defp do_validate(%{"anyOf" => alts}, v, p) do
    # the alternative with the fewest errors decides: none -> keep its warnings, some -> one union message
    # an alternative the value matched structurally (errors only inside) beats one it did not
    # match at all, then fewer errors wins
    best =
      alts
      |> Enum.map(&do_validate(&1, v, p))
      |> Enum.min_by(fn problems ->
        errors = Enum.filter(problems, &match?({:error, _, _}, &1))
        {Enum.any?(errors, fn {_, path, _} -> path == p end), length(errors)}
      end)

    if Enum.any?(best, &match?({:error, ^p, _}, &1)),
      do: [{:error, p, "expected #{describe(%{"anyOf" => alts})}, got #{short(v)}"}],
      else: best
  end

  # atoms other than nil/booleans go on the wire as strings
  defp do_validate(%{"enum" => allowed}, v, p) do
    wire = if is_atom(v) and v not in [nil, true, false], do: Atom.to_string(v), else: v

    if wire in allowed,
      do: [],
      else: [{:error, p, "expected one of #{inspect(allowed)}, got #{short(v)}"}]
  end

  defp do_validate(%{"type" => "object"} = s, %{} = v, p) do
    v = Map.new(v, fn {k, val} -> {to_string(k), val} end)
    props = Map.get(s, "properties", %{})
    required = Map.get(s, "required", [])

    missing =
      for k <- required,
          not Map.has_key?(v, k),
          do: {:error, p <> "/" <> k, "missing required key"}

    extra =
      for k <- Map.keys(v),
          not Map.has_key?(props, k),
          do: {:warn, p <> "/" <> k, "key not in type"}

    nested =
      Enum.flat_map(props, fn {k, sub} ->
        case Map.fetch(v, k) do
          {:ok, val} -> do_validate(sub, val, p <> "/" <> k)
          :error -> []
        end
      end)

    missing ++ extra ++ nested
  end

  defp do_validate(%{"type" => "array"} = s, v, p) when is_list(v) do
    items = Map.get(s, "items", %{"type" => "any"})
    v |> Enum.with_index() |> Enum.flat_map(fn {el, i} -> do_validate(items, el, "#{p}/#{i}") end)
  end

  # atoms other than nil/booleans go on the wire as strings
  defp do_validate(%{"type" => "string"}, v, _p)
       when is_binary(v) or (is_atom(v) and v not in [nil, true, false]),
       do: []

  defp do_validate(%{"type" => "number"}, v, _p) when is_number(v), do: []
  defp do_validate(%{"type" => "boolean"}, v, _p) when is_boolean(v), do: []
  defp do_validate(%{"type" => "null"}, nil, _p), do: []
  defp do_validate(s, v, p), do: [{:error, p, "expected #{describe(s)}, got #{short(v)}"}]

  defp describe(%{"type" => t}), do: t
  defp describe(%{"enum" => e}), do: "one of #{inspect(e)}"

  defp describe(%{"anyOf" => a}),
    do: a |> Enum.map(&describe/1) |> Enum.uniq() |> Enum.join(" | ")

  defp short(v), do: v |> inspect() |> String.slice(0, 60)
end
