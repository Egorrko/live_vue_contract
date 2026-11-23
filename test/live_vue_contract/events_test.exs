defmodule LiveVueContract.EventsTest do
  # handle_event/3 of a real LiveView module, wrapped by `use LiveVueContract`, against a small
  # contract with two declarations of "save" (nested/Card and Other) and one of "refresh".
  use ExUnit.Case, async: false

  alias LiveVueContract.{Coverage, Events}

  @object fn props, required ->
    %{"type" => "object", "properties" => props, "required" => required}
  end

  @contract %{
    "Board" => @object.(%{}, []),
    "nested/Card" => @object.(%{"label" => %{"type" => "string"}}, ["label"]),
    "Other" => @object.(%{}, []),
    "$events" => %{
      "save" => [
        %{
          "payload" => @object.(%{"id" => %{"type" => "number"}}, ["id"]),
          "reply" => @object.(%{"ok" => %{"type" => "boolean"}}, ["ok"]),
          "components" => ["Board", "nested/Card"],
          "declared" => ["assets/vue/nested/Card.vue"]
        },
        %{
          "payload" => @object.(%{"name" => %{"type" => "string"}}, ["name"]),
          "reply" => nil,
          "components" => ["Other"],
          "declared" => ["assets/vue/Other.vue"]
        }
      ],
      "refresh" => [
        %{
          "payload" => @object.(%{}, []),
          "reply" => @object.(%{"at" => %{"type" => "string"}}, ["at"]),
          "components" => ["Board"],
          "declared" => ["assets/vue/board.ts"]
        }
      ]
    }
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "lvc_events_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "contract.json")
    File.write!(path, JSON.encode!(@contract))
    Application.put_env(:live_vue_contract, :contract, path)

    on_exit(fn ->
      Application.delete_env(:live_vue_contract, :contract)
      Application.delete_env(:live_vue_contract, :validate)
      File.rm_rf!(dir)
    end)

    Process.delete({Events, :rendered})
    :ok
  end

  # a LiveView whose catch-all handle_event returns what `push/4` put in the process dictionary
  defp live_view do
    mod = :"Elixir.LiveVueContract.EventsTest.L#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{inspect(mod)} do
      use Phoenix.LiveView
      use LiveVueContract

      @impl true
      def render(assigns), do: ~H|<.vue v-component="Board" />|

      @impl true
      def handle_event("refresh", _params, socket), do: {:reply, %{at: ~D[2026-11-23]}, socket}
      def handle_event("phx", _params, socket), do: {:noreply, socket}
      def handle_event(_event, _params, socket), do: Process.get(:return) |> put_elem(tuple_size(Process.get(:return)) - 1, socket)
    end
    """)

    mod
  end

  defp push(mod, event, params, return) do
    Process.put(:return, return)
    mod.handle_event(event, params, %Phoenix.LiveView.Socket{})
  end

  test "an event from a rendered component: payload and reply are checked" do
    mod = live_view()
    Events.rendered("nested/Card")

    assert {:reply, %{ok: true}, _} = push(mod, "save", %{"id" => 1}, {:reply, %{ok: true}, nil})

    e = assert_raise ArgumentError, fn -> push(mod, "save", %{"id" => "1"}, {:noreply, nil}) end
    assert e.message =~ ~s|the payload of pushEvent("save") to #{inspect(mod)}|
    assert e.message =~ "/id: expected number"
    assert e.message =~ "assets/vue/nested/Card.vue"

    e =
      assert_raise ArgumentError, fn ->
        push(mod, "save", %{"id" => 1}, {:reply, %{ok: "yes"}, nil})
      end

    assert e.message =~ ~s|the reply of handle_event("save")|
    assert e.message =~ "/ok: expected boolean"

    e = assert_raise ArgumentError, fn -> push(mod, "save", %{"id" => 1}, {:noreply, nil}) end
    assert e.message =~ "returned {:noreply, socket}, the client awaits a reply"
  end

  test "the reply is checked in its JSON form" do
    mod = live_view()
    Events.rendered("Board")
    socket = %Phoenix.LiveView.Socket{}
    assert {:reply, %{at: ~D[2026-11-23]}, _} = mod.handle_event("refresh", %{}, socket)
  end

  test "the declaration of the component that was rendered applies" do
    mod = live_view()
    Events.rendered("Other")

    assert {:noreply, _} = push(mod, "save", %{"name" => "n"}, {:noreply, nil})

    assert_raise ArgumentError, ~r|/name: missing required key|, fn ->
      push(mod, "save", %{"id" => 1}, {:noreply, nil})
    end
  end

  test "two rendered components declaring one event differently is an error" do
    mod = live_view()
    Events.rendered("nested/Card")
    Events.rendered("Other")

    assert_raise ArgumentError, ~r/declared with different types/, fn ->
      push(mod, "save", %{"id" => 1}, {:noreply, nil})
    end
  end

  test "events nobody rendered declares, and pages without Vue components, are left alone" do
    mod = live_view()
    assert {:noreply, _} = push(mod, "save", %{"anything" => true}, {:noreply, nil})

    Events.rendered("Other")
    assert {:noreply, _} = push(mod, "phx", %{"value" => "x"}, {:noreply, nil})
  end

  test "validate: :warn logs instead of raising" do
    mod = live_view()
    Events.rendered("nested/Card")
    Application.put_env(:live_vue_contract, :validate, :warn)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:noreply, _} = push(mod, "save", %{"id" => "1"}, {:noreply, nil})
      end)

    assert log =~ "/id: expected number"
  end

  test "validation off at compile time: handle_event is not wrapped" do
    Application.put_env(:live_vue_contract, :validate, false)
    mod = live_view()
    Application.delete_env(:live_vue_contract, :validate)
    Events.rendered("nested/Card")

    assert {:noreply, _} = push(mod, "save", %{"id" => "1"}, {:noreply, nil})
  end

  test "templates list the components they render; coverage reports the rest" do
    mod = live_view()
    assert mod.__live_vue_tags__() == ["Board"]

    report = Coverage.report(:live_vue_contract)
    assert %{events: events} = report
    assert Enum.map(events, &elem(&1, 0)) == ["refresh", "save"]
    assert Coverage.format(report) =~ "never pushed: refresh (assets/vue/board.ts)"
  end
end
