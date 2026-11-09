defmodule Eab.Results.Resources do
  @moduledoc false
  import Eab.Results.Schema
  @identity ~w(model_artifact backend backend_version context_tokens kv_cache cpu)
  @ram ~w(ram_rss_bytes ram_lifetime_peak_bytes service_ram_bytes service_ram_lifetime_peak_bytes)
  @snapshot ~w(kind observed_at gpus) ++ @identity ++ @ram
  @sampled ~w(kind started_at finished_at gpus peak_vram_bytes peak_ram_bytes peak_rss_bytes peak_combined_bytes sample_count interval_ms session_count coverage gap_count) ++
             @identity

  def weight_files(nil, _artifact, _backend), do: nil

  def weight_files(memory, artifact, backend) do
    observed =
      for session <- memory["sessions"] || [], session["sample_count"] > 0 do
        identity = session["identity"] || %{}
        files = identity["weight_files"]
        size = files["size_bytes"]

        if identity["model_artifact"] == artifact and identity["backend"] == backend and
             is_integer(size) and size > 0,
           do: files
      end

    case Enum.uniq(observed) do
      [files] -> files
      _ -> nil
    end
  end

  def from_run!(nil), do: nil

  def from_run!(memory) do
    require!(
      memory["kind"] == "run_samples" and memory["status"] in ~w(complete partial),
      "Run memory collection has not finished"
    )

    sessions = memory["sessions"]
    observed = Enum.filter(sessions, &(&1["sample_count"] > 0))

    if observed != [] do
      first = hd(observed)
      identity = first["identity"]

      require!(
        Enum.all?(observed, &(&1["identity"] == identity)),
        "Memory sessions used different deployments; do not combine hardware requirements"
      )

      ids = Enum.map(first["gpus"], & &1["uuid"])

      require!(
        Enum.all?(observed, &(Enum.map(&1["gpus"], fn gpu -> gpu["uuid"] end) == ids)),
        "Memory sessions used different physical GPUs"
      )

      gpus =
        Enum.with_index(ids)
        |> Enum.map(fn {_, i} ->
          cards = Enum.map(observed, &Enum.at(&1["gpus"], i))

          require!(
            Enum.uniq_by(cards, &Map.take(&1, ~w(name capacity_bytes))) |> length() == 1,
            "GPU hardware changed"
          )

          hd(cards)
          |> Map.take(~w(name capacity_bytes))
          |> Map.put("used_bytes", cards |> Enum.map(& &1["used_bytes"]) |> Enum.max())
        end)

      peaks = memory["peaks"]

      # A Strata pack folder names no model; publish the first weight file found behind it.
      artifact =
        case get_in(identity, ["weight_files", "files"]) do
          [%{"name" => name} | _] when is_binary(name) ->
            if Eab.ModelIdentity.folder?(identity["model_artifact"]),
              do: name,
              else: identity["model_artifact"]

          _ ->
            identity["model_artifact"]
        end

      Map.merge(Map.take(identity, @identity), %{
        "model_artifact" => artifact,
        "kind" => "run_samples",
        "started_at" => hd(sessions)["started_at"],
        "finished_at" => List.last(sessions)["finished_at"],
        "gpus" => gpus,
        "peak_vram_bytes" => peaks["vram_bytes"],
        "peak_ram_bytes" => peaks["service_ram_bytes"],
        "peak_rss_bytes" => peaks["process_rss_bytes"],
        "peak_combined_bytes" => peaks["combined_bytes"],
        "sample_count" => memory["sample_count"],
        "interval_ms" => first["interval_ms"],
        "session_count" => length(sessions),
        "coverage" => memory["status"],
        "gap_count" => Enum.sum(Enum.map(sessions, & &1["gap_count"]))
      })
    end
  end

  def validate!(r, model, settings) do
    require!(is_map(r), "Expected resource object")
    sampled = r["kind"] == "run_samples"
    fields!(r, if(sampled, do: @sampled, else: @snapshot), "Unexpected resource fields")
    require!(r["kind"] in ~w(loaded_snapshot run_samples), "Unsupported resource observation")

    for key <- if(sampled, do: ~w(started_at finished_at), else: ~w(observed_at)),
        do: date!(r[key])

    if sampled do
      require!(r["coverage"] in ~w(complete partial), "Memory collection has not finished")

      for key <-
            ~w(sample_count interval_ms session_count peak_vram_bytes peak_ram_bytes peak_rss_bytes peak_combined_bytes),
          do: require!(positive?(r[key]), "Invalid #{key}")

      require!(nonnegative?(r["gap_count"]), "Invalid gap count")

      require!(
        r["coverage"] != "complete" or r["gap_count"] == 0,
        "Complete coverage cannot contain gaps"
      )

      require!(
        r["peak_combined_bytes"] >= max(r["peak_vram_bytes"], r["peak_ram_bytes"]) and
          r["peak_combined_bytes"] <= r["peak_vram_bytes"] + r["peak_ram_bytes"],
        "Invalid simultaneous memory peak"
      )
    else
      for key <- @ram,
          do: require!(is_nil(r[key]) or positive?(r[key]), "Invalid RAM observation")
    end

    require!(r["backend"] == model["backend"], "Resource backend differs from run")

    require!(
      positive?(r["context_tokens"]) and
        if(sampled,
          do: r["context_tokens"] >= (settings["window_tokens"] || 0),
          else: r["context_tokens"] == settings["window_tokens"]
        ),
      "Resource observation must use the run's context limit"
    )

    artifact = text!(r["model_artifact"], "model_artifact")
    require!(Path.basename(artifact) == artifact, "Only the artifact filename is public")
    identity = Eab.ModelIdentity.details(%{"profile" => %{"model_path" => artifact}})

    require!(
      Eab.ModelIdentity.folder?(artifact) or
        (identity["name"] == model["name"] and identity["quantization"] == model["quantization"]),
      "Resource observation is for a different model artifact"
    )

    for key <- ~w(cpu backend_version), do: text!(r[key], key)
    require!(is_nil(r["kv_cache"]) or is_binary(r["kv_cache"]), "Invalid KV cache type")
    require!(is_list(r["gpus"]) and r["gpus"] != [], "Missing process GPU allocation")

    for gpu <- r["gpus"] do
      fields!(gpu, ~w(name capacity_bytes used_bytes), "Unexpected GPU fields")
      text!(gpu["name"], "GPU name")

      require!(
        positive?(gpu["capacity_bytes"]) and positive?(gpu["used_bytes"]) and
          gpu["used_bytes"] <= gpu["capacity_bytes"],
        "Invalid GPU allocation"
      )
    end

    r
  end
end
