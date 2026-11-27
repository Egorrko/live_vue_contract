defmodule LiveVueContract.RenderTest do
  # vue/1 checks every prop on the first render and afterwards only those in __changed__
  use ExUnit.Case, async: false

  @contract %{
    "Panel" => %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "rows" => %{"type" => "array", "items" => %{"type" => "number"}}
      },
      "required" => ["title", "rows"]
    }
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "lvc_render_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "contract.json")
    File.write!(path, JSON.encode!(@contract))
    Application.put_env(:live_vue_contract, :contract, path)

    on_exit(fn ->
      Application.delete_env(:live_vue_contract, :contract)
      Application.delete_env(:live_vue_contract, :strict)
      File.rm_rf!(dir)
    end)
  end

  defp vue(props, changed) do
    %{"v-component": "Panel", "v-ssr": false, id: "panel", __changed__: changed}
    |> Map.merge(props)
    |> LiveVueContract.vue()
  end

  test "the first render checks every prop" do
    assert_raise ArgumentError, ~r"/rows/1: expected number", fn ->
      vue(%{title: "t", rows: [1, "2"]}, nil)
    end
  end

  test "an update checks the props that changed" do
    assert_raise ArgumentError, ~r"/title: expected string", fn ->
      vue(%{title: 1, rows: [1]}, %{title: true})
    end
  end

  test "an update does not walk the props that stayed" do
    assert %Phoenix.LiveView.Rendered{} = vue(%{title: "t", rows: [1, "2"]}, %{title: true})
  end

  test "a required prop gone on an update is reported" do
    assert_raise ArgumentError, ~r"/rows: missing required key", fn ->
      vue(%{title: "t"}, %{title: true})
    end
  end

  test "a prop that appears on an update is checked against the type" do
    Application.put_env(:live_vue_contract, :strict, true)

    assert_raise ArgumentError, ~r"/extra: key not in type", fn ->
      vue(%{title: "t", rows: [], extra: 1}, %{extra: true})
    end
  end

  test "a shared prop the component does not declare is not reported" do
    Application.put_env(:live_vue, :shared_props, [:flash, {:current_user, :user}])
    Application.put_env(:live_vue_contract, :strict, true)
    on_exit(fn -> Application.delete_env(:live_vue, :shared_props) end)

    assert %Phoenix.LiveView.Rendered{} =
             vue(%{title: "t", rows: [], flash: %{}, user: nil}, nil)
  end

  test "items a LiveStream inserts are checked against the array's item type" do
    stream = Phoenix.LiveView.LiveStream.new(:rows, "ref", [], [])

    ok = Phoenix.LiveView.LiveStream.insert_item(stream, %{id: 1, n: 5}, -1, nil, false)
    # a stream of maps against number[]: each item is reported once, with its DOM id
    error =
      assert_raise ArgumentError, fn ->
        vue(%{title: "t", rows: ok}, nil)
      end

    assert error.message =~ "/rows/N: expected number, got %{"
    assert error.message =~ "(stream item rows-1)"
  end

  test "a rewritten contract is read again, names resolved again" do
    assert {:ok, "Panel", _} = LiveVueContract.Schema.resolve("Panel")
    path = Application.fetch_env!(:live_vue_contract, :contract)
    File.write!(path, JSON.encode!(%{"other/Panel" => @contract["Panel"]}))

    assert {:ok, "other/Panel", _} = LiveVueContract.Schema.resolve("Panel")
  end

  test "a mismatch deep in a big value is reported with a short message" do
    rows = List.duplicate(1, 100_000)

    error =
      assert_raise ArgumentError, fn ->
        vue(%{title: "t", rows: rows ++ [%{big: List.duplicate("x", 100_000)}]}, nil)
      end

    assert error.message =~ "/rows/100000: expected number, got %{big: "
    assert byte_size(error.message) < 300
  end
end
