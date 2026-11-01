# Generator tests run node against test/fixtures/app (`npm ci --prefix test/fixtures/app`).
# Without its node_modules they are skipped locally; CI sets LIVE_VUE_CONTRACT_NODE=1 so a broken
# install fails instead of skipping.
node_ready? =
  System.find_executable("node") != nil and
    File.dir?("test/fixtures/app/node_modules/vue-component-meta")

cond do
  node_ready? ->
    ExUnit.start()

  System.get_env("LIVE_VUE_CONTRACT_NODE") ->
    raise "node or test/fixtures/app/node_modules missing: run `npm ci --prefix test/fixtures/app`"

  true ->
    IO.puts("Skipping :node tests: run `npm ci --prefix test/fixtures/app` to include them")
    ExUnit.start(exclude: [:node])
end
