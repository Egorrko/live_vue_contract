defmodule LiveVueContract.Report do
  @moduledoc false
  # Turns validator problems into an ArgumentError (errors) and one-time log warnings, honouring
  # `validate: :warn` and `strict: true`. Shared by props and events.

  require Logger

  @doc """
  `problems` from `LiveVueContract.Schema.validate/3`; `subject` names what was checked
  (`<.vue v-component="X">`), `source` where its type is declared (`defineProps in X.vue`).
  """
  def raise_or_warn!(problems, subject, source) do
    strict? = Application.get_env(:live_vue_contract, :strict, false)
    warn_only? = Application.get_env(:live_vue_contract, :validate) == :warn

    {errors, warnings} =
      Enum.split_with(problems, fn {sev, _, _} ->
        not warn_only? and (sev == :error or strict?)
      end)

    for {_sev, path, msg} <- warnings, warn_once?({subject, path}) do
      Logger.warning("#{subject}: #{path(path)}: #{msg} (#{source})")
    end

    if errors != [] do
      raise ArgumentError, """
      #{subject} does not match #{source}:

      #{Enum.map_join(errors, "\n", fn {_sev, path, msg} -> "  #{path(path)}: #{msg}" end)}
      """
    end

    :ok
  end

  defp path(""), do: "/"
  defp path(path), do: path

  @doc "Logs `message` once per `key` for the life of the VM."
  def warn_once(key, message) do
    if warn_once?(key), do: Logger.warning(message)
    :ok
  end

  defp warn_once?({subject, path}) when is_binary(path) do
    # array paths differ only by index; collapse them so one warning per key, not per row
    first?({subject, Regex.replace(~r"/\d+(/|$)", path, "/N\\1")})
  end

  defp warn_once?(key), do: first?(key)

  defp first?(key) do
    key = {__MODULE__, key}

    if :persistent_term.get(key, false) do
      false
    else
      :persistent_term.put(key, true)
      true
    end
  end
end
