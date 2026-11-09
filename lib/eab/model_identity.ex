defmodule Eab.ModelIdentity do
  @moduledoc "Human-readable artifact identity, separate from the API routing alias."
  @quant ~r/(?:^|[-.])((?:UD-)?(?:IQ|Q|TQ|MXFP|NVFP|BF|FP|F)\d[A-Z0-9_]*)(?:$)/i
  @local ~w(llama_cpp strata)

  # Identities saved before pack folders were recognised named the model after the folder.
  def details(%{"identity" => %{"version" => 1} = identity} = endpoint) do
    if endpoint["backend"] in @local and folder?(identity["artifact"]),
      do: endpoint |> Map.delete("identity") |> details(),
      else: identity
  end

  def details(endpoint) when is_map(endpoint) do
    profile = endpoint["profile"] || %{}
    props = get_in(endpoint, ["metadata", "props"]) || %{}
    row = get_in(endpoint, ["metadata", "model"]) || %{}
    meta = row["meta"] || %{}
    served = served_artifact(endpoint)
    # Strata reports the pack folder it serves from, which names no weight file.
    artifact = if not folder?(served), do: served

    stem =
      if artifact do
        artifact
        |> String.replace(~r/\.gguf$/i, "")
        |> String.replace(~r/-\d{5}-of-\d{5}$/, "")
      end

    file_quant = if stem, do: Regex.run(@quant, stem, capture: :all_but_first)

    quant =
      case file_quant do
        [value] -> String.upcase(value)
        _ -> normalize_quant(meta["ftype"] || row["ftype"] || profile["model_ftype"])
      end

    name =
      cond do
        stem && stem not in ["model", "weights"] -> String.replace(stem, @quant, "")
        present(meta["name"]) -> meta["name"]
        present(props["model_name"]) -> props["model_name"]
        true -> endpoint["model"] || "Unknown model"
      end

    %{
      "version" => 1,
      "name" => name,
      "quantization" => quant,
      "artifact" => artifact,
      "source" => if(artifact, do: "reported_artifact", else: "reported_name"),
      "size_bytes" => positive(meta["size"] || row["size"] || props["model_size_bytes"]),
      "parameter_count" => positive(meta["n_params"] || row["n_params"])
    }
  end

  def details(_), do: details(%{})

  @doc "Last part of the server-reported model path: a weight file, or Strata's pack folder."
  def served_artifact(endpoint) do
    path =
      present(get_in(endpoint, ["profile", "model_path"])) ||
        present(get_in(endpoint, ["metadata", "props", "model_path"]))

    if path, do: Path.basename(path)
  end

  @doc "Whether a served path's last part is a folder, such as a Strata pack, not a weight file."
  def folder?(name), do: is_binary(name) and Path.extname(name) == ""

  @doc "Identity named by the weight files the memory collector found on the model host."
  def from_files(%{"files" => [%{"name" => name} | _]}) when is_binary(name),
    do: Map.put(details(%{"profile" => %{"model_path" => name}}), "source", "host_files")

  def from_files(_), do: nil

  def attach(endpoint), do: Map.put(endpoint || %{}, "identity", details(endpoint))

  def label(endpoint) do
    identity = details(endpoint)

    if identity["quantization"],
      do: identity["name"] <> " · " <> identity["quantization"],
      else: identity["name"]
  end

  def size_label(endpoint) do
    case details(endpoint)["size_bytes"] do
      bytes when is_number(bytes) -> "#{Float.round(bytes / 1_000_000_000, 1)} GB"
      _ -> "Not reported"
    end
  end

  defp normalize_quant(value) when is_binary(value) do
    value
    |> String.upcase()
    |> String.replace(~r/\s*-\s*MEDIUM$/, "_M")
    |> String.replace(~r/\s*-\s*SMALL$/, "_S")
    |> String.replace(~r/\s*-\s*LARGE$/, "_L")
    |> present()
  end

  defp normalize_quant(_), do: nil
  defp present(value) when is_binary(value), do: if(String.trim(value) != "", do: value)
  defp present(_), do: nil
  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_), do: nil
end
