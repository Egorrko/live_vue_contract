defmodule LiveVueContractTest do
  use ExUnit.Case, async: true

  alias LiveVueContract.Schema

  # what gen.mjs emits for defineProps<{ items: { id: string; label: string; n: number | null }[]; on: boolean }>()
  @schema %{
    "type" => "object",
    "required" => ["items", "on"],
    "properties" => %{
      "items" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["id", "label", "n"],
          "properties" => %{
            "id" => %{"type" => "string"},
            "label" => %{"type" => "string"},
            "n" => %{"anyOf" => [%{"type" => "null"}, %{"type" => "number"}]}
          }
        }
      },
      "on" => %{"type" => "boolean"}
    }
  }

  test "matching props pass, atoms count as strings" do
    assert Schema.validate(@schema, %{items: [%{id: "1", label: :ok, n: nil}], on: true}) == []
  end

  test "renamed nested key: missing is an error, the stray one a warning" do
    assert [{:error, "/items/0/label", _}, {:warn, "/items/0/status_label", _}] =
             Schema.validate(@schema, %{items: [%{id: "1", status_label: "x", n: 1}], on: true})
  end

  test "enum accepts the atom that becomes that string on the wire; a nested union reports inside" do
    schema = %{
      "type" => "object",
      "required" => ["kind", "profile"],
      "properties" => %{
        "kind" => %{"enum" => ["text", "image"]},
        "profile" => %{
          "anyOf" => [
            %{"type" => "null"},
            %{
              "type" => "object",
              "required" => ["name"],
              "properties" => %{"name" => %{"type" => "string"}}
            }
          ]
        }
      }
    }

    assert Schema.validate(schema, %{kind: :text, profile: nil}) == []
    assert [{:error, "/kind", _}] = Schema.validate(schema, %{kind: :video, profile: nil})

    assert [{:error, "/profile/name", "missing required key"}] =
             Schema.validate(schema, %{kind: :text, profile: %{}})

    assert [{:error, "/profile", msg}] = Schema.validate(schema, %{kind: :text, profile: 5})
    assert msg =~ "expected null | object"
  end

  test "string where number expected" do
    assert [{:error, "/items/0/n", msg}] =
             Schema.validate(@schema, %{items: [%{id: "1", label: "l", n: "3"}], on: false})

    assert msg =~ "expected null | number"
  end

  test "tag attribute names against the schema" do
    assert Schema.check_keys(@schema, [:"v-component", :items, :on, :"v-on:click", :id]) == []

    assert ["missing required prop \"on\"", "prop \"total\" is not declared in defineProps"] =
             Schema.check_keys(@schema, [:items, :total])
  end

  test "fetch resolves names like LiveVue's findComponent" do
    path =
      Path.join(System.tmp_dir!(), "live_vue_contract_#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      JSON.encode!(%{
        "$sources" => "abc",
        "HomePage" => %{"type" => "object", "properties" => %{}},
        "components/ui/Dialog" => %{"type" => "object", "properties" => %{"a" => %{}}},
        "prototypes/players/0-freakdex/index" => %{
          "type" => "object",
          "properties" => %{"b" => %{}}
        },
        "admin/Dialog" => %{"type" => "object", "properties" => %{"c" => %{}}}
      })
    )

    Application.put_env(:live_vue_contract, :contract, path)

    try do
      assert {:ok, %{"properties" => %{}}} = Schema.fetch("HomePage")
      assert {:ok, %{"properties" => %{"a" => _}}} = Schema.fetch("ui/Dialog")
      assert {:ok, %{"properties" => %{"b" => _}}} = Schema.fetch("prototypes/players/0-freakdex")
      assert {:ambiguous, ["admin/Dialog", "components/ui/Dialog"]} = Schema.fetch("Dialog")
      assert :error = Schema.fetch("Nope")
      assert Enum.sort(Schema.shortcut_names()) == ["Dialog", "HomePage", "index"]
    after
      Application.delete_env(:live_vue_contract, :contract)
      File.rm(path)
    end
  end
end
