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
  # Events declared with `useLiveEvents<...>()` (0.4.0+): name -> variants.
  @events "$events"

  @doc "Path of the contract file, relative to the host app's cwd."
  def path, do: Application.get_env(:live_vue_contract, :contract, "assets/vue/contract.json")

  @doc "All schemas keyed by component name; `%{}` when the file is absent."
  def all, do: load() |> elem(1)

  @doc "Named types the schemas refer to with `{\"$ref\": name}`."
  def defs, do: load() |> elem(2)

  @doc """
  Events declared with `useLiveEvents<...>()`: event name -> list of variants
  `%{"payload" => schema, "reply" => schema | nil, "components" => [key], "declared" => [file]}`.
  One event name has several variants when components declare it with different types.
  """
  def events, do: load() |> elem(3)

  # `{stamp, schemas, defs, events}`: the file is parsed again when its stamp changes (the
  # generator rewrote it under a running dev server); `stamp` is nil when there is no file.
  defp load do
    path = path()

    case File.stat(path) do
      {:ok, %{mtime: mtime, size: size}} ->
        stamp = {path, mtime, size}

        case :persistent_term.get({__MODULE__, path}, nil) do
          {^stamp, _schemas, _defs, _events} = loaded ->
            loaded

          _ ->
            contract = path |> File.read!() |> JSON.decode!() |> Map.delete(@sources)
            {defs, contract} = Map.pop(contract, @defs, %{})
            {events, schemas} = Map.pop(contract, @events, %{})

            loaded = {stamp, schemas, defs, events}
            :persistent_term.put({__MODULE__, path}, loaded)
            loaded
        end

      _ ->
        {nil, %{}, %{}, %{}}
    end
  end

  @doc "Shortcut tag names (`<.ComponentName>`): file basenames, like `LiveVue.Components`."
  def shortcut_names, do: all() |> Map.keys() |> Enum.map(&Path.basename/1) |> Enum.uniq()

  @doc """
  Schema for a `v-component` name: `{:ok, schema}`, `:error`, or `{:ambiguous, keys}`.
  Matches by path suffix with `index` segments ignored, exactly like `findComponent` in LiveVue's JS.
  """
  def fetch(name) do
    case resolve(name) do
      {:ok, _key, schema} -> {:ok, schema}
      other -> other
    end
  end

  @doc "Like `fetch/1`, with the contract key the name resolved to: `{:ok, key, schema}`."
  def resolve(name) do
    # called on every render; matching the name against every key took 0.1 ms with 200
    # components, so the answer is kept in the process (a LiveView renders the same names)
    case load() do
      {nil, schemas, _defs, _events} ->
        resolve(name, schemas)

      {stamp, schemas, _defs, _events} ->
        key = {__MODULE__, :resolve, name}

        case Process.get(key) do
          {^stamp, resolved} ->
            resolved

          _ ->
            resolved = resolve(name, schemas)
            Process.put(key, {stamp, resolved})
            resolved
        end
    end
  end

  defp resolve(name, schemas) do
    parts =
      name
      |> String.replace_suffix(".vue", "")
      |> String.split("/")
      |> Enum.reject(&(&1 == "index"))

    matches =
      for {key, schema} <- schemas, suffix?(key_parts(key), parts), do: {key, schema}

    case matches do
      [{key, schema}] -> {:ok, key, schema}
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

  @doc """
  Prop names `LiveVue.SharedPropsView` injects into every tag (`config :live_vue, :shared_props`).
  A component may leave them out of `defineProps`: Vue passes an undeclared prop on as an attribute.
  """
  def shared_props do
    for entry <- Application.get_env(:live_vue, :shared_props, []) do
      case entry do
        {_source, target} -> to_string(target)
        name -> to_string(name)
      end
    end
  end

  @doc "Attribute names of a `<.vue>` tag that LiveVue would send as props."
  def prop_keys(keys) do
    keys
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in @special or String.starts_with?(&1, ["v-on:", "v-inject:"])))
  end

  @doc """
  Compares attribute names with the schema. Returns `[]` or a list of problems.
  `shared` are props injected by `LiveVue.SharedPropsView` (always present on the wire): they
  count as passed, and a component that does not declare them is fine.
  """
  def check_keys(%{"properties" => props} = schema, keys, shared \\ []) do
    shared = Enum.map(shared, &to_string/1)
    keys = prop_keys(keys)
    required = Map.get(schema, "required", [])
    missing = required -- (keys ++ shared)
    extra = (keys -- shared) -- Map.keys(props)

    Enum.map(missing, &"missing required prop #{inspect(&1)}") ++
      Enum.map(extra, &"prop #{inspect(&1)} is not declared in defineProps")
  end

  @doc """
  Item schema of an array schema (through `$ref` and `T[] | null`), or `nil`.
  """
  def items(schema, defs \\ defs())
  def items(%{"type" => "array"} = s, _defs), do: Map.get(s, "items", %{"type" => "any"})
  def items(%{"$ref" => name}, defs), do: items(Map.get(defs, name), defs)

  def items(%{"anyOf" => alts}, defs) do
    case alts |> Enum.map(&items(&1, defs)) |> Enum.reject(&is_nil/1) do
      [items] -> items
      _ -> nil
    end
  end

  def items(_schema, _defs), do: nil

  @doc """
  Validates an encoded (JSON-ready) props map.

  Returns `[]` or `[{severity, path, message}]`. A key the TS type does not declare is
  `:warn` (TypeScript is structural; the client just never reads it), everything else is `:error`.
  `defs` resolves `{"$ref": name}`; by default, the named types of the contract file.
  """
  def validate(schema, value, defs \\ defs()) do
    for {severity, path, message} <- check(schema, value, [], defs) do
      {severity, format_path(path), format_message(message, defs)}
    end
  end

  # The walk runs on every render with big props, so it builds no strings: a path is a reversed
  # list of segments, a message a tuple. Both are formatted only for the problems `validate/3`
  # returns: a union tries every alternative and drops the losers' problems, and a message
  # inspected eagerly for each of them cost more than the walk itself.
  defp check(%{"type" => "any"}, _v, _p, _d), do: []

  defp check(%{"$ref" => name}, v, p, d) do
    case Map.fetch(d, name) do
      {:ok, schema} -> check(schema, v, p, d)
      :error -> raise ArgumentError, "#{path()}: $ref #{inspect(name)} is not in $defs"
    end
  end

  defp check(%{"anyOf" => alts}, v, p, d) do
    # the alternative with the fewest errors (then warnings) decides: none -> keep its warnings, some -> one union message
    # an alternative the value matched structurally (errors only inside) beats one it did not
    # match at all; then one whose literal keys agree with the value (`ok: false` picks
    # `{ ok: false; error: string }` out of a discriminated union); then fewer errors
    case check_alternatives(alts, v, p, d, []) do
      [] -> []
      tried -> pick_alternative(alts, tried, v, p, d)
    end
  end

  # atoms other than nil/booleans go on the wire as strings
  defp check(%{"enum" => allowed}, v, p, _d) do
    if wire(v) in allowed,
      do: [],
      else: [{:error, p, {:one_of, allowed, v}}]
  end

  defp check(%{"type" => "object"} = s, %{} = v, p, d) do
    v = Map.new(v, fn {k, val} -> {to_string(k), val} end)
    props = Map.get(s, "properties", %{})
    required = Map.get(s, "required", [])

    missing =
      for k <- required,
          not Map.has_key?(v, k),
          do: {:error, [k | p], :missing}

    # keys outside `properties`: checked against an index signature / Record value type when
    # there is one, otherwise a warning
    extra =
      for {k, val} <- v, not Map.has_key?(props, k), problem <- extra_key(s, k, val, p, d) do
        problem
      end

    nested =
      Enum.flat_map(props, fn {k, sub} ->
        case Map.fetch(v, k) do
          {:ok, val} -> check(sub, val, [k | p], d)
          :error -> []
        end
      end)

    missing ++ extra ++ nested
  end

  defp check(%{"type" => "array"} = s, v, p, d) when is_list(v) do
    items = Map.get(s, "items", %{"type" => "any"})
    check_items(v, items, 0, p, d)
  end

  # atoms other than nil/booleans go on the wire as strings
  defp check(%{"type" => "string"}, v, _p, _d)
       when is_binary(v) or (is_atom(v) and v not in [nil, true, false]),
       do: []

  defp check(%{"type" => "number"}, v, _p, _d) when is_number(v), do: []
  defp check(%{"type" => "boolean"}, v, _p, _d) when is_boolean(v), do: []
  defp check(%{"type" => "null"}, nil, _p, _d), do: []
  defp check(s, v, p, _d), do: [{:error, p, {:expected, s, v}}]

  defp check_items([], _items, _i, _p, _d), do: []

  defp check_items([el | rest], items, i, p, d) do
    case check(items, el, [i | p], d) do
      [] -> check_items(rest, items, i + 1, p, d)
      problems -> problems ++ check_items(rest, items, i + 1, p, d)
    end
  end

  # `[]` as soon as one alternative matches cleanly (no problem can rank better), otherwise
  # every alternative with its problems
  defp check_alternatives([], _v, _p, _d, tried), do: Enum.reverse(tried)

  defp check_alternatives([alt | rest], v, p, d, tried) do
    case check(alt, v, p, d) do
      [] -> []
      problems -> check_alternatives(rest, v, p, d, [{alt, problems} | tried])
    end
  end

  defp pick_alternative(alts, tried, v, p, d) do
    best =
      tried
      |> Enum.min_by(fn {alt, problems} ->
        errors = Enum.filter(problems, &match?({:error, _, _}, &1))

        # last, fewer unknown keys: `Partial<A> | Partial<B>` all match with no errors, the
        # branch that declares the keys the value carries is the one meant
        {Enum.any?(errors, fn {_, path, _} -> path == p end), discriminant_mismatch?(alt, v, d),
         length(errors), length(problems) - length(errors)}
      end)
      |> elem(1)

    if Enum.any?(best, &match?({:error, ^p, _}, &1)),
      do: [{:error, p, {:expected, %{"anyOf" => alts}, v}}],
      else: best
  end

  # an object alternative with a single-literal property (a union tag) the value disagrees with
  defp discriminant_mismatch?(%{"$ref" => name}, v, d),
    do: discriminant_mismatch?(Map.get(d, name, %{}), v, d)

  defp discriminant_mismatch?(%{"type" => "object", "properties" => props}, %{} = v, _d) do
    v = Map.new(v, fn {k, val} -> {to_string(k), val} end)

    Enum.any?(props, fn
      {k, %{"enum" => [literal]}} -> Map.has_key?(v, k) and wire(v[k]) != literal
      _ -> false
    end)
  end

  defp discriminant_mismatch?(_alt, _v, _d), do: false

  defp wire(v) when is_atom(v) and v not in [nil, true, false], do: Atom.to_string(v)
  defp wire(v), do: v

  defp extra_key(%{"additionalProperties" => sub}, k, val, p, d),
    do: check(sub, val, [k | p], d)

  defp extra_key(_s, k, _val, p, _d), do: [{:warn, [k | p], :not_in_type}]

  defp format_path(path),
    do: path |> Enum.reverse() |> Enum.map_join(&["/", to_string(&1)])

  defp format_message(:missing, _d), do: "missing required key"
  defp format_message(:not_in_type, _d), do: "key not in type"

  defp format_message({:one_of, allowed, v}, _d),
    do: "expected one of #{inspect(allowed)}, got #{short(v)}"

  defp format_message({:expected, s, v}, d), do: "expected #{describe(s, d)}, got #{short(v)}"

  defp describe(%{"$ref" => name}, d), do: d |> Map.get(name, %{"type" => name}) |> describe(d)
  defp describe(%{"type" => t}, _d), do: t
  defp describe(%{"enum" => e}, _d), do: "one of #{inspect(e)}"

  defp describe(%{"anyOf" => a}, d),
    do: a |> Enum.map(&describe(&1, d)) |> Enum.uniq() |> Enum.join(" | ")

  # a megabyte list in the wrong place is not inspected whole to show 60 characters of it
  defp short(v),
    do: v |> inspect(limit: 10, printable_limit: 60) |> String.slice(0, 60)
end
