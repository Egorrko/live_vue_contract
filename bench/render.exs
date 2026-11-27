# Render-time cost of the props check against the size of the props.
#
#     mix run bench/render.exs
#
# A synthetic dashboard: charts with a nullable discriminated union of results (a table of
# string | number | null cells or a series of points). Per size: LiveVueContract.validate!/1 on
# the first render, on an update that changed one small prop, on an update that changed the big
# one, and LiveVue.vue/1 rendering every prop, for scale. Medians, in ms.

defmodule Bench do
  @contract %{
    "Dashboard" => %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "charts" => %{"type" => "array", "items" => %{"$ref" => "Chart"}},
        "filters" => %{"type" => "array", "items" => %{"$ref" => "Filter"}}
      },
      "required" => ["title", "charts", "filters"]
    },
    "$defs" => %{
      "Chart" => %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string"},
          "title" => %{"type" => "string"},
          "status" => %{"enum" => ["ok", "error", "loading"]},
          "result" => %{
            "anyOf" => [
              %{"type" => "null"},
              %{
                "type" => "object",
                "properties" => %{
                  "kind" => %{"enum" => ["table"]},
                  "columns" => %{"type" => "array", "items" => %{"type" => "string"}},
                  "rows" => %{
                    "type" => "array",
                    "items" => %{
                      "type" => "object",
                      "additionalProperties" => %{
                        "anyOf" => [
                          %{"type" => "string"},
                          %{"type" => "number"},
                          %{"type" => "null"}
                        ]
                      }
                    }
                  }
                },
                "required" => ["kind", "columns", "rows"]
              },
              %{
                "type" => "object",
                "properties" => %{
                  "kind" => %{"enum" => ["series"]},
                  "points" => %{
                    "type" => "array",
                    "items" => %{
                      "type" => "object",
                      "properties" => %{
                        "x" => %{"type" => "number"},
                        "y" => %{"type" => "number"}
                      },
                      "required" => ["x", "y"]
                    }
                  }
                },
                "required" => ["kind", "points"]
              }
            ]
          }
        },
        "required" => ["id", "title", "status", "result"]
      },
      "Filter" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "options" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["name", "options"]
      }
    }
  }

  def setup do
    path = Path.join(System.tmp_dir!(), "live_vue_contract_bench.json")
    File.write!(path, JSON.encode!(@contract))
    Application.put_env(:live_vue_contract, :contract, path)
    Application.put_env(:live_vue_contract, :validate, true)
  end

  def chart(i) do
    result =
      if rem(i, 2) == 0 do
        %{
          kind: "table",
          columns: ["region", "orders", "revenue", "note"],
          rows:
            for(r <- 1..20, do: %{region: "R#{r}", orders: r * 7, revenue: r * 1.5, note: nil})
        }
      else
        %{kind: "series", points: for(x <- 1..40, do: %{x: x, y: x * 0.5})}
      end

    %{id: "c#{i}", title: "Chart #{i}", status: :ok, result: result}
  end

  def props(charts) do
    %{
      title: "Dashboard",
      charts: Enum.map(1..charts//1, &chart/1),
      filters: for(f <- 1..5, do: %{name: "f#{f}", options: Enum.map(1..30, &"opt#{&1}")})
    }
  end

  def assigns(props, changed) do
    Map.merge(props, %{"v-component": "Dashboard", "v-ssr": false, id: "d", __changed__: changed})
  end

  # median of n runs, in microseconds
  def time(n, fun) do
    fun.()
    times = for _ <- 1..n, do: fun |> :timer.tc() |> elem(0)
    times |> Enum.sort() |> Enum.at(div(n, 2))
  end

  def run do
    setup()

    IO.puts(
      "charts  props_kb  check_first_ms  check_small_update_ms  check_big_update_ms  live_vue_first_ms"
    )

    for charts <- [0, 1, 10, 100, 250, 1000] do
      props = props(charts)
      kb = (props |> JSON.encode!() |> byte_size()) / 1024
      first = assigns(props, nil)
      small = assigns(%{props | title: "Dashboard 2"}, %{title: true})
      big = assigns(props, %{charts: true})
      n = if charts >= 100, do: 15, else: 101

      row = [
        time(n, fn -> LiveVueContract.validate!(first) end),
        time(n, fn -> LiveVueContract.validate!(small) end),
        time(n, fn -> LiveVueContract.validate!(big) end),
        # what LiveVue itself does on the first render: encode and serialize every prop
        time(n, fn -> first |> LiveVue.vue() |> Phoenix.HTML.Safe.to_iodata() end)
      ]

      IO.puts(
        :io_lib.format(
          "~6B  ~8.1f  ~14.2f  ~21.2f  ~19.2f  ~17.2f",
          [charts, kb | Enum.map(row, &(&1 / 1000))]
        )
      )
    end
  end
end

unless System.get_env("BENCH_NO_RUN"), do: Bench.run()
