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
  # Written by 0.1.0 into the contract itself; skipped when reading an old file.
  @sources "$sources"
  # Named types shared by components (0.3.0+), referenced from schemas as `{"$ref": name}`.
  @defs "$defs"

  @doc "Path of the contract file, relative to the host app's cwd."
  def path, do: Application.get_env(:live_vue_contract, :contract, "assets/vue/contract.json")

  @doc "All schemas keyed by component name; `%{}` when the file is absent."
  def all, do: load() |> elem(0)

  @doc "Named types the schemas refer to with `{\"$ref\": name}`."
  def defs, do: load() |> elem(1)

  defp load do
    path = path()

    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        case :persistent_term.get({__MODULE__, path}, nil) do
          {^mtime, schemas, defs} ->
            {schemas, defs}

          _ ->
            {defs, schemas} =
              path
              |> File.read!()
              |> JSON.decode!()
              |> Map.delete(@sources)
              |> Map.pop(@defs, %{})

            :persistent_term.put({__MODULE__, path}, {mtime, schemas, defs})
            {schemas, defs}
        end

      _ ->
        {%{}, %{}}
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
  `defs` resolves `{"$ref": name}`; by default, the named types of the contract file.
  """
  def validate(schema, value, defs \\ defs()), do: do_validate(schema, value, "", defs)

  defp do_validate(%{"type" => "any"}, _v, _p, _d), do: []

  defp do_validate(%{"$ref" => name}, v, p, d) do
    case Map.fetch(d, name) do
      {:ok, schema} -> do_validate(schema, v, p, d)
      :error -> raise ArgumentError, "#{path()}: $ref #{inspect(name)} is not in $defs"
    end
  end

  defp do_validate(%{"anyOf" => alts}, v, p, d) do
    # the alternative with the fewest errors decides: none -> keep its warnings, some -> one union message
    # an alternative the value matched structurally (errors only inside) beats one it did not
    # match at all, then fewer errors wins
    best =
      alts
      |> Enum.map(&do_validate(&1, v, p, d))
      |> Enum.min_by(fn problems ->
        errors = Enum.filter(problems, &match?({:error, _, _}, &1))
        {Enum.any?(errors, fn {_, path, _} -> path == p end), length(errors)}
      end)

    if Enum.any?(best, &match?({:error, ^p, _}, &1)),
      do: [{:error, p, "expected #{describe(%{"anyOf" => alts}, d)}, got #{short(v)}"}],
      else: best
  end

  # atoms other than nil/booleans go on the wire as strings
  defp do_validate(%{"enum" => allowed}, v, p, _d) do
    wire = if is_atom(v) and v not in [nil, true, false], do: Atom.to_string(v), else: v

    if wire in allowed,
      do: [],
      else: [{:error, p, "expected one of #{inspect(allowed)}, got #{short(v)}"}]
  end

  defp do_validate(%{"type" => "object"} = s, %{} = v, p, d) do
    v = Map.new(v, fn {k, val} -> {to_string(k), val} end)
    props = Map.get(s, "properties", %{})
    required = Map.get(s, "required", [])

    missing =
      for k <- required,
          not Map.has_key?(v, k),
          do: {:error, p <> "/" <> k, "missing required key"}

    # keys outside `properties`: checked against an index signature / Record value type when
    # there is one, otherwise a warning
    extra =
      for {k, val} <- v, not Map.has_key?(props, k), problem <- extra_key(s, k, val, p, d) do
        problem
      end

    nested =
      Enum.flat_map(props, fn {k, sub} ->
        case Map.fetch(v, k) do
          {:ok, val} -> do_validate(sub, val, p <> "/" <> k, d)
          :error -> []
        end
      end)

    missing ++ extra ++ nested
  end

  defp do_validate(%{"type" => "array"} = s, v, p, d) when is_list(v) do
    items = Map.get(s, "items", %{"type" => "any"})

    v
    |> Enum.with_index()
    |> Enum.flat_map(fn {el, i} -> do_validate(items, el, "#{p}/#{i}", d) end)
  end

  # atoms other than nil/booleans go on the wire as strings
  defp do_validate(%{"type" => "string"}, v, _p, _d)
       when is_binary(v) or (is_atom(v) and v not in [nil, true, false]),
       do: []

  defp do_validate(%{"type" => "number"}, v, _p, _d) when is_number(v), do: []
  defp do_validate(%{"type" => "boolean"}, v, _p, _d) when is_boolean(v), do: []
  defp do_validate(%{"type" => "null"}, nil, _p, _d), do: []
  defp do_validate(s, v, p, d), do: [{:error, p, "expected #{describe(s, d)}, got #{short(v)}"}]

  defp extra_key(%{"additionalProperties" => sub}, k, val, p, d),
    do: do_validate(sub, val, p <> "/" <> k, d)

  defp extra_key(_s, k, _val, p, _d), do: [{:warn, p <> "/" <> k, "key not in type"}]

  defp describe(%{"$ref" => name}, d), do: d |> Map.get(name, %{"type" => name}) |> describe(d)
  defp describe(%{"type" => t}, _d), do: t
  defp describe(%{"enum" => e}, _d), do: "one of #{inspect(e)}"

  defp describe(%{"anyOf" => a}, d),
    do: a |> Enum.map(&describe(&1, d)) |> Enum.uniq() |> Enum.join(" | ")

  defp short(v), do: v |> inspect() |> String.slice(0, 60)
end
