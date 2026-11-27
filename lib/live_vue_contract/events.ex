defmodule LiveVueContract.Events do
  @moduledoc """
  Render-time check of events a Vue component sends with `pushEvent`, against the types it
  declared with `useLiveEvents<...>()` from the `live_vue_contract` npm package.

  `use LiveVueContract` wraps `handle_event/3` of a LiveView or LiveComponent in dev and test
  (it is not compiled in when validation is off at compile time, as in `MIX_ENV=prod`):

    * the params are checked against the declared `payload`;
    * `{:reply, map, socket}` is checked against the declared `reply` after a JSON round trip,
      the form the client receives; `{:noreply, socket}` for an event that declares a reply is
      an error, the client awaits a reply that never comes.

  Which declaration applies is decided by the Vue components this LiveView process has rendered:
  an event is checked only when one of them (or a child component or composable it imports)
  declares it. A `phx-click` with the same name on a page without such a component is left alone.
  """

  alias LiveVueContract.{Coverage, Report, Schema}

  @rendered {__MODULE__, :rendered}

  @doc false
  # Called by `LiveVueContract.vue/1` in the LiveView process for every rendered component.
  def rendered(key) do
    set = Process.get(@rendered, MapSet.new())
    unless MapSet.member?(set, key), do: Process.put(@rendered, MapSet.put(set, key))
    :ok
  end

  @doc false
  # Wrapped `handle_event/3`: checks the params, calls the original, checks its result.
  def handle(module, event, params, fun) do
    variant = payload!(module, event, params)
    result = fun.()
    reply!(module, event, variant, result)
  end

  @doc """
  The declarations of `event` that apply in this process: those of the components it rendered.
  Usually one; several when components rendered together declare the event with different types.
  """
  def variants(event) do
    with variants when is_list(variants) <- Map.get(Schema.events(), event),
         rendered when rendered != %MapSet{} <- Process.get(@rendered, MapSet.new()) do
      Enum.filter(variants, fn v -> Enum.any?(v["components"], &MapSet.member?(rendered, &1)) end)
    else
      _ -> []
    end
  end

  # The declaration the params match decides, and its reply type checks the reply: two components
  # on one page may each push `save` with their own payload. Params that match none are reported
  # against the declaration they come closest to.
  defp payload!(module, event, params) do
    case variants(event) do
      [] ->
        nil

      variants ->
        Coverage.record(:event, event)

        {variant, problems} =
          variants
          |> Enum.map(&{&1, Schema.validate(&1["payload"], params)})
          |> Enum.min_by(fn {_variant, problems} ->
            errors = Enum.count(problems, &match?({:error, _, _}, &1))
            {errors, length(problems) - errors}
          end)

        Report.raise_or_warn!(
          problems,
          ~s|the payload of pushEvent(#{inspect(event)}) to #{inspect(module)}|,
          "the payload type in useLiveEvents of #{declared(variant)}"
        )

        variant
    end
  end

  defp reply!(_module, _event, nil, result), do: result

  defp reply!(module, event, variant, result) do
    subject = ~s|the reply of handle_event(#{inspect(event)}) in #{inspect(module)}|

    case {variant["reply"], result} do
      {nil, {:reply, _map, _socket}} ->
        Report.warn_once(
          {module, event, :reply},
          "handle_event(#{inspect(event)}) in #{inspect(module)} replies, but useLiveEvents of " <>
            "#{declared(variant)} declares no reply: the client ignores it"
        )

      {nil, _} ->
        :ok

      {schema, {:reply, map, _socket}} ->
        schema
        |> Schema.validate(wire(map))
        |> Report.raise_or_warn!(
          subject,
          "the reply type in useLiveEvents of #{declared(variant)}"
        )

      {_schema, {:noreply, _socket}} ->
        Report.raise_or_warn!(
          [{:error, "", "handle_event returned {:noreply, socket}, the client awaits a reply"}],
          subject,
          "the reply type in useLiveEvents of #{declared(variant)}"
        )

      _ ->
        :ok
    end

    result
  end

  # What the client receives: the reply goes through the channel's JSON serializer.
  defp wire(map),
    do:
      map |> Phoenix.json_library().encode_to_iodata!() |> IO.iodata_to_binary() |> JSON.decode!()

  defp declared(variant), do: Enum.join(variant["declared"], ", ")
end
