defmodule Eab.Results.Machine do
  @moduledoc """
  The machine a run's model was served on, as published (ADR 0020): its GPUs, CPU and system
  RAM, the server and its build, the KV cache type and the server's speed-related flags.

  The memory collector reads these on the model host. Only flags on the allowlist below are
  published, under their long names, because the full command line also holds file paths,
  the host, the port and the API key file. A draft model's path is reduced to its file name.
  Strata records no command line, so its flags are null.
  """
  import Eab.Results.Schema, only: [fields!: 3, require!: 2, positive?: 1, text!: 2]

  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  @fields ~w(gpus cpu ram_bytes server server_build kv_cache flags)

  # Long name => short aliases, for llama.cpp server flags that change speed or placement.
  @flags %{
    "--n-gpu-layers" => ~w(-ngl --gpu-layers),
    "--split-mode" => ~w(-sm),
    "--tensor-split" => ~w(-ts),
    "--main-gpu" => ~w(-mg),
    "--device" => ~w(-dev),
    "--override-tensor" => ~w(-ot),
    "--cpu-moe" => ~w(-cmoe),
    "--n-cpu-moe" => ~w(-ncmoe),
    "--flash-attn" => ~w(-fa),
    "--cache-type-k" => ~w(-ctk),
    "--cache-type-v" => ~w(-ctv),
    "--no-kv-offload" => ~w(-nkvo),
    "--kv-unified" => ~w(-kvu),
    "--swa-full" => [],
    "--batch-size" => ~w(-b),
    "--ubatch-size" => ~w(-ub),
    "--threads" => ~w(-t),
    "--threads-batch" => ~w(-tb),
    "--parallel" => ~w(-np),
    "--ctx-size" => ~w(-c),
    "--cont-batching" => ~w(-cb),
    "--no-cont-batching" => ~w(-nocb),
    "--mlock" => [],
    "--no-mmap" => [],
    "--numa" => [],
    "--fit" => [],
    "--load-mode" => [],
    "--cache-ram" => ~w(-cram),
    "--cache-reuse" => [],
    "--ctx-checkpoints" => [],
    "--prio" => [],
    "--poll" => [],
    "--cpu-mask" => ~w(-C),
    "--cpu-range" => ~w(-Cr),
    "--cpu-strict" => [],
    "--spec-type" => [],
    "--spec-draft-n-max" => [],
    "--spec-draft-n-min" => [],
    "--spec-draft-p-min" => [],
    "--spec-draft-type-k" => [],
    "--spec-draft-type-v" => [],
    "--model-draft" => ~w(-md),
    "--draft-max" => ~w(--draft --draft-n),
    "--draft-min" => ~w(--draft-n-min),
    "--draft-p-min" => [],
    "--gpu-layers-draft" => ~w(-ngld --n-gpu-layers-draft),
    "--device-draft" => ~w(-devd),
    "--cache-type-k-draft" => ~w(-ctkd),
    "--cache-type-v-draft" => ~w(-ctvd),
    "--ctx-size-draft" => ~w(-cd),
    "--override-tensor-draft" => ~w(-otd)
  }
  @names for {long, aliases} <- @flags, name <- [long | aliases], into: %{}, do: {name, long}

  def flag_names, do: Map.keys(@flags)

  @doc "The machine of a run's memory record, or nil when no session identified one."
  def from_run(nil), do: nil

  def from_run(memory) do
    machines =
      for session <- memory["sessions"] || [],
          is_map(session["identity"]) and (session["sample_count"] || 0) > 0,
          do: of_session(session)

    case Enum.uniq(machines) do
      [] ->
        nil

      [machine] ->
        machine

      _ ->
        raise ArgumentError,
              "Memory sessions used different machines; publish them as separate runs"
    end
  end

  defp of_session(session) do
    identity = session["identity"]

    %{
      "gpus" =>
        Enum.map(
          session["gpus"] || [],
          &%{"name" => &1["name"], "memory_bytes" => &1["capacity_bytes"]}
        ),
      "cpu" => identity["cpu"],
      "ram_bytes" => session["host_ram_bytes"],
      "server" => identity["backend"],
      "server_build" => identity["backend_version"],
      "kv_cache" => identity["kv_cache"],
      "flags" => flags(identity["server_args"])
    }
  end

  @doc """
  The allowlisted flags of a server command line, by long name: a flag's value, or true for
  a flag without one. A repeated flag's values are joined with a space. Nil without a command line.
  """
  def flags(args) when is_list(args) and args != [] do
    args |> tl() |> parse(%{})
  end

  def flags(_), do: nil

  defp parse([], acc), do: acc

  defp parse([token | rest], acc) do
    if flag?(token) do
      {name, inline} =
        case String.split(token, "=", parts: 2) do
          [name, value] -> {name, value}
          [name] -> {name, nil}
        end

      {value, rest} =
        cond do
          inline -> {inline, rest}
          rest != [] and not flag?(hd(rest)) -> {hd(rest), tl(rest)}
          true -> {true, rest}
        end

      acc =
        case @names[name] do
          nil -> acc
          long -> Map.update(acc, long, public(long, value), &join(&1, public(long, value)))
        end

      parse(rest, acc)
    else
      parse(rest, acc)
    end
  end

  # A negative number such as "-1" is a value, not a flag.
  defp flag?(token), do: is_binary(token) and Regex.match?(~r/^--?[A-Za-z]/, token)

  defp public("--model-draft", value) when is_binary(value), do: Path.basename(value)
  defp public(_, value), do: value

  defp join(a, b) when is_binary(a) and is_binary(b), do: a <> " " <> b
  defp join(_, b), do: b

  def validate!(nil), do: :ok

  def validate!(machine) do
    fields!(machine, @fields, "Unexpected machine fields")
    require!(is_list(machine["gpus"]), "A machine lists its GPUs")

    for gpu <- machine["gpus"] do
      fields!(gpu, ~w(name memory_bytes), "Unexpected machine GPU fields")
      text!(gpu["name"], "GPU name")
      require!(positive?(gpu["memory_bytes"]), "Invalid GPU memory")
    end

    # A collector that could not read the CPU or the server's build reports none.
    for key <- ~w(cpu server_build),
        do: require!(is_nil(machine[key]) or text?(machine[key]), "Invalid #{key}")

    require!(machine["server"] in ~w(llama_cpp strata), "Unknown model server")

    require!(
      is_nil(machine["ram_bytes"]) or positive?(machine["ram_bytes"]),
      "Invalid system RAM"
    )

    require!(
      is_nil(machine["kv_cache"]) or is_binary(machine["kv_cache"]),
      "Invalid KV cache type"
    )

    flags = machine["flags"]
    require!(is_nil(flags) or is_map(flags), "Server flags must be an object or null")

    for {name, value} <- flags || %{} do
      require!(Map.has_key?(@flags, name), "Unexpected server flag: #{name}")

      require!(
        value === true or
          (is_binary(value) and String.length(value) <= 200 and String.trim(value) != ""),
        "Invalid value for #{name}"
      )
    end

    :ok
  end
end
