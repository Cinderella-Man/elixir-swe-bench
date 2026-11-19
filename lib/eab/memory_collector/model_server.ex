defmodule Eab.ModelServer do
  @moduledoc """
  Which model server answers at an endpoint, from its `/health` and `/props` replies. Discovery
  and the model-host memory collector both use it, so they agree; it lives beside the collector
  because the collector's own release compiles only that folder.
  """

  @doc "\"maya\", \"strata\" or \"llama_cpp\"."
  def kind(health, props) do
    cond do
      maya?(health) ->
        "maya"

      health["service"] == "strata" or
          String.contains?(String.downcase(to_string(props["build_info"])), "strata") ->
        "strata"

      true ->
        "llama_cpp"
    end
  end

  @doc "The server's build as it reports it, or nil."
  def build(health, props) do
    if maya?(health),
      do:
        Enum.join(["Project Maya " <> health["version"] | List.wrap(props["build_info"])], " · "),
      else: props["build_info"]
  end

  # Project Maya, a Strata fork, has a /health of its own: no service field, its model label and
  # its version. Its /props names a "Strata <version>" build when its engine reports one, so it
  # is told apart before Strata.
  defp maya?(health),
    do:
      not Map.has_key?(health, "service") and is_binary(health["model_label"]) and
        is_binary(health["version"])
end
