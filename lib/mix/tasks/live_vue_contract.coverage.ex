defmodule Mix.Tasks.LiveVueContract.Coverage do
  @shortdoc "Merges the coverage of partitioned test runs into one report"
  @moduledoc """
  Prints one `LiveVueContract.Coverage` report for a run split into partitions
  (`mix test --partitions N`, or `start(export: name)`), then deletes the partition files.

      MIX_TEST_PARTITION=1 mix test --partitions 2
      MIX_TEST_PARTITION=2 mix test --partitions 2
      mix live_vue_contract.coverage

  The files live in `_build/live_vue_contract_coverage`, shared by all environments; run the task
  with `MIX_ENV=test` so it reuses the test build. `--keep` leaves the files in place.
  """
  use Mix.Task

  alias LiveVueContract.Coverage

  @requirements ["app.config"]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [keep: :boolean])

    case Coverage.merge(Mix.Project.config()[:app]) do
      {_report, []} ->
        Mix.raise(
          "no coverage in #{Path.relative_to_cwd(Coverage.dir())}: " <>
            "run the partitions with LiveVueContract.Coverage.start() in test_helper.exs first"
        )

      {report, files} ->
        Mix.shell().info(Coverage.format(report))
        unless opts[:keep], do: Enum.each(files, &File.rm!/1)
    end
  end
end
