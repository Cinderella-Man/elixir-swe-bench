defmodule Eab.MemoryCollector.Weights do
  @moduledoc false

  # Count the exact GGUF file or its complete, numbered shard set, or the files a Strata
  # pack lists. Optional metadata must not prevent memory collection when files are unavailable.
  def read(path) when is_binary(path) do
    files = if File.dir?(path), do: pack(path), else: paths(path)

    if files != [] do
      observations =
        Enum.reduce_while(files, [], fn file, acc ->
          case File.stat(file) do
            {:ok, %{type: :regular, size: size}} when size > 0 ->
              {:cont, [%{"name" => Path.basename(file), "size_bytes" => size} | acc]}

            _ ->
              {:halt, nil}
          end
        end)

      if observations do
        found = %{
          "size_bytes" => Enum.sum(Enum.map(observations, & &1["size_bytes"])),
          "files" => Enum.reverse(observations)
        }

        # The first file (shard 1) holds the metadata.
        case quantized_by(hd(files)) do
          nil -> found
          creator -> Map.put(found, "quantized_by", creator)
        end
      end
    end
  end

  def read(_), do: nil

  # Who made the quantization, as the GGUF names itself (general.quantized_by): "Unsloth",
  # "ISTA DASLab". Makers often write it after the tokenizer's arrays, so the read covers the
  # key/value section of a large vocabulary (about 12 MB for 248k tokens), not the weights.
  # A file that names no one, or a header that does not parse, names no one.
  @header_bytes 64 * 1024 * 1024
  @fixed %{
    0 => 1,
    1 => 1,
    2 => 2,
    3 => 2,
    4 => 4,
    5 => 4,
    6 => 4,
    7 => 1,
    10 => 8,
    11 => 8,
    12 => 8
  }

  def quantized_by(file) do
    case File.open(file, [:read, :binary], &IO.binread(&1, @header_bytes)) do
      {:ok, <<"GGUF", version::little-32, _tensors::little-64, count::little-64, rest::binary>>}
      when version in 2..3 ->
        entries(rest, min(count, 4096))

      _ ->
        nil
    end
  end

  defp entries(<<size::little-64, key::binary-size(size), type::little-32, rest::binary>>, left)
       when left > 0 do
    case value(type, rest) do
      {text, _} when key == "general.quantized_by" and is_binary(text) ->
        text = String.trim(text)
        if String.valid?(text) and byte_size(text) in 1..100, do: text

      {_, rest} ->
        entries(rest, left - 1)

      nil ->
        nil
    end
  end

  defp entries(_, _), do: nil

  defp value(8, <<size::little-64, text::binary-size(size), rest::binary>>), do: {text, rest}

  defp value(9, <<type::little-32, count::little-64, rest::binary>>) when type != 9,
    do: skip(type, count, rest)

  defp value(type, rest) when is_map_key(@fixed, type) do
    size = @fixed[type]

    case rest do
      <<_::binary-size(^size), rest::binary>> -> {nil, rest}
      _ -> nil
    end
  end

  defp value(_, _), do: nil

  # Arrays are skipped: string arrays one length at a time, the rest by their element size.
  defp skip(_, 0, rest), do: {nil, rest}

  defp skip(8, count, rest) do
    case value(8, rest) do
      {_, rest} -> skip(8, count - 1, rest)
      nil -> nil
    end
  end

  defp skip(type, count, rest) when is_map_key(@fixed, type) do
    size = @fixed[type] * count

    case rest do
      <<_::binary-size(^size), rest::binary>> -> {nil, rest}
      _ -> nil
    end
  end

  defp skip(_, _, _), do: nil

  defp paths(path) do
    case Regex.run(~r/\A(.*)-(\d{5})-of-(\d{5})\.gguf\z/, path) do
      [_, prefix, index, count] ->
        count_number = String.to_integer(count)

        # Bound work for malformed metadata; real model shard sets are much smaller.
        if count_number in 1..1024 and String.to_integer(index) in 1..count_number do
          for i <- 1..count_number,
              do: "#{prefix}-#{String.pad_leading(to_string(i), 5, "0")}-of-#{count}.gguf"
        else
          []
        end

      nil ->
        if Path.extname(path) == ".gguf", do: [path], else: []
    end
  end

  # Strata serves from a pack folder. Its tensors.txt lists the GGUF files the engine reads
  # ("file <n> <name>") and the file holding each tensor ("t <name> <type> <n> ..."); ds4.txt
  # names the folder holding the files. A pack may mix shards of one release with a file
  # from another, so count what it lists, except a file holding only the speculative
  # drafter's (mtp.*) tensors, which is not the model.
  defp pack(dir) do
    listing = Path.join(dir, "tensors.txt")

    {files, drafter} =
      if File.regular?(listing) do
        listing
        |> File.stream!()
        |> Enum.reduce({[], %{}}, fn line, {files, drafter} ->
          case String.split(String.trim_trailing(line), " ", parts: 3) do
            ["file", index, name] ->
              {[{index, name} | files], drafter}

            ["t", tensor, placement] ->
              index = placement |> String.split(" ", parts: 3) |> Enum.at(1)
              only = String.starts_with?(tensor, "mtp.")
              {files, Map.update(drafter, index, only, &(&1 and only))}

            _ ->
              {files, drafter}
          end
        end)
      else
        {[], %{}}
      end

    names = for {index, name} <- Enum.reverse(files), drafter[index] != true, do: name
    folder = model_dir(dir)

    if names != [] and length(names) <= 1024 and Enum.all?(names, &(&1 =~ ~r/\A[^\/]+\.gguf\z/)),
      do: Enum.map(names, &Path.join(folder, &1)),
      else: []
  rescue
    File.Error -> []
  end

  defp model_dir(dir) do
    config = Path.join(dir, "ds4.txt")

    listed =
      if File.regular?(config) do
        config
        |> File.stream!()
        |> Enum.find_value(fn line ->
          case String.split(String.trim_trailing(line), " ", parts: 2) do
            ["model_dir", folder] -> folder
            _ -> nil
          end
        end)
      end

    listed || Path.dirname(dir)
  end
end
