defmodule LiveVueContract.GeneratorTest do
  # priv/gen.mjs and the Mix compiler against test/fixtures/app: a few .vue files whose
  # defineProps cover every shape the generator maps. The expected contract is checked in, so an
  # upgrade of vue-component-meta or TypeScript that changes the output shows up as a diff.
  # After a deliberate change: LIVE_VUE_CONTRACT_UPDATE=1 mix test test/live_vue_contract/generator_test.exs
  use ExUnit.Case, async: false

  @moduletag :node

  alias LiveVueContract.Schema

  @fixture Path.expand("../fixtures/app", __DIR__)
  @expected Path.join(@fixture, "contract.expected.json")

  setup do
    tmp = Path.join(System.tmp_dir!(), "lvc_gen_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    for entry <- ~w(assets tsconfig.json package.json),
        do: File.cp_r!(Path.join(@fixture, entry), Path.join(tmp, entry))

    File.ln_s!(Path.join(@fixture, "node_modules"), Path.join(tmp, "node_modules"))
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{app: tmp}
  end

  defp generate(app) do
    script = Path.join(:code.priv_dir(:live_vue_contract), "gen.mjs")
    args = [script, "tsconfig.json", "contract.json", "deps.json", "assets/vue"]
    {out, 0} = System.cmd("node", args, cd: app, stderr_to_stdout: true)
    assert out =~ "3 components"
    File.read!(Path.join(app, "contract.json"))
  end

  test "the contract matches the checked-in expectation", %{app: app} do
    json = generate(app)

    if System.get_env("LIVE_VUE_CONTRACT_UPDATE"), do: File.write!(@expected, json)

    assert json == File.read!(@expected), """
    priv/gen.mjs output for test/fixtures/app changed. If that is intended, rerun with
    LIVE_VUE_CONTRACT_UPDATE=1 and review the diff of #{Path.relative_to_cwd(@expected)}.
    """
  end

  test "deps list the .vue files and the .ts files prop types come from", %{app: app} do
    generate(app)

    assert app |> Path.join("deps.json") |> File.read!() |> JSON.decode!() ==
             ~w(assets/vue/Kitchen.vue assets/vue/nested/Card.vue assets/vue/nested/index.vue assets/vue/types.ts)
  end

  describe "generated schemas validate wire values" do
    setup %{app: app} do
      generate(app)
      Application.put_env(:live_vue_contract, :contract, Path.join(app, "contract.json"))
      on_exit(fn -> Application.delete_env(:live_vue_contract, :contract) end)
    end

    @author %{name: "a", avatar: nil}
    @valid %{
      title: "t",
      count: 1,
      done: false,
      maybe: nil,
      status: :open,
      level: 2,
      size: "s",
      slug: "a-1",
      tags: ["x"],
      pair: ["a", 1],
      author: @author,
      editor: @author,
      comments: [
        %{
          id: 1,
          body: "b",
          author: @author,
          replies: [%{id: 2, body: "c", author: @author, replies: []}]
        }
      ],
      scores: %{"a" => 1, b: 2},
      authors_by_id: %{"1" => @author},
      totals: %{open: 1, closed: 0},
      index: %{x: true},
      settings: %{theme: "dark"},
      picked: %{theme: "dark"},
      tagged: %{id: "1", label: "l"},
      meta: %{anything: 1},
      anchor: nil,
      when: "2026-01-01",
      lookup: %{},
      callback: nil,
      anything: [1]
    }

    defp problems(change), do: Schema.validate(Schema.all()["Kitchen"], Map.merge(@valid, change))

    test "a value matching every prop passes" do
      assert problems(%{}) == []
      assert problems(%{note: "n", flag: true, settings: %{}}) == []
    end

    test "Record and index signatures check their values, not their keys" do
      assert [{:error, "/scores/b", "expected number, got \"2\""}] =
               problems(%{scores: %{b: "2"}})

      assert [{:error, "/index/x", _}] = problems(%{index: %{x: 1}})

      assert [{:error, "/authors_by_id/1/name", "missing required key"}] =
               problems(%{authors_by_id: %{"1" => %{avatar: nil}}})
    end

    test "Record with literal keys, Partial and Pick" do
      assert [{:error, "/totals/closed", "missing required key"}] =
               problems(%{totals: %{open: 1}})

      assert [{:error, "/settings/volume", _}] = problems(%{settings: %{volume: "loud"}})
      assert [{:error, "/picked/theme", "missing required key"}] = problems(%{picked: %{}})
    end

    test "shared and recursive named types are checked at every use" do
      assert [{:error, "/editor/name", _}] = problems(%{editor: %{avatar: nil}})

      deep = [
        %{
          id: 1,
          body: "b",
          author: @author,
          replies: [%{id: "2", body: "c", author: @author, replies: []}]
        }
      ]

      assert [{:error, "/comments/0/replies/0/id", _}] = problems(%{comments: deep})
    end

    test "enums, literal unions, tuples and intersections" do
      assert [{:error, "/size", _}] = problems(%{size: "m"})
      assert [{:error, "/level", _}] = problems(%{level: 4})
      assert [{:error, "/pair/1", _}] = problems(%{pair: ["a", true]})
      assert [{:error, "/tagged/id", "missing required key"}] = problems(%{tagged: %{label: "l"}})
    end
  end

  describe "Mix compiler" do
    setup %{app: app} do
      stamp = Path.join(Mix.Project.manifest_path(), "compile.live_vue_contract")
      File.rm(stamp)
      prev = File.cwd!()
      File.cd!(app)

      on_exit(fn ->
        File.cd!(prev)
        File.rm(stamp)
      end)
    end

    test "runs node only when a source of the contract changed", %{app: app} do
      run = fn -> Mix.Tasks.Compile.LiveVueContract.run([]) end
      contract = Path.join(app, "assets/vue/contract.json")

      assert {:ok, []} = run.()
      assert File.exists?(contract)
      assert {:noop, []} = run.()

      # a file no prop type comes from
      File.write!(Path.join(app, "assets/vue/unused.ts"), "export const x = 1\n")
      assert {:noop, []} = run.()

      File.write!(
        Path.join(app, "assets/vue/types.ts"),
        File.read!(Path.join(app, "assets/vue/types.ts")) <>
          "\nexport type Extra = { a: string }\n"
      )

      before = File.stat!(contract).mtime
      assert {:ok, []} = run.()
      # same schemas: the contract is not rewritten, so ~H modules are not recompiled
      assert File.stat!(contract).mtime == before

      File.write!(
        Path.join(app, "assets/vue/nested/Card.vue"),
        File.read!(Path.join(app, "assets/vue/nested/Card.vue"))
        |> String.replace("label: string", "label: string; size: number")
      )

      assert {:ok, []} = run.()

      assert contract |> File.read!() |> JSON.decode!() |> get_in(["nested/Card", "required"]) ==
               ["label", "size"]
    end
  end
end
