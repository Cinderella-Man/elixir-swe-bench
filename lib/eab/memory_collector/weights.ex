defmodule Eab.MemoryCollector.Weights do
  @moduledoc false

  # Only count the exact GGUF file or its complete, numbered shard set.
  # Optional metadata must not prevent memory collection when files are unavailable.
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
        %{
          "size_bytes" => Enum.sum(Enum.map(observations, & &1["size_bytes"])),
          "files" => Enum.reverse(observations)
        }
      end
    end
  end

  def read(_), do: nil

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

  # Strata serves from a pack folder. Its tensors.txt opens with the GGUF files the engine
  # reads ("file <n> <name>") and ds4.txt names the folder holding them. A drafter listed
  # beside the model's one numbered shard set is not the model; any other mix is unknown.
  defp pack(dir) do
    listing = Path.join(dir, "tensors.txt")

    names =
      if File.regular?(listing) do
        listing
        |> File.stream!()
        |> Stream.map(&String.trim_trailing/1)
        |> Stream.take_while(&String.starts_with?(&1, "file "))
        |> Stream.take(1025)
        |> Enum.flat_map(fn line ->
          case String.split(line, " ", parts: 3) do
            ["file", _, name] -> if name =~ ~r/\A[^\/]+\.gguf\z/, do: [name], else: [nil]
            _ -> [nil]
          end
        end)
      else
        []
      end

    folder = model_dir(dir)
    sets = Enum.filter(names, &(&1 && &1 =~ ~r/-\d{5}-of-\d{5}\.gguf\z/))

    cond do
      nil in names or length(names) > 1024 -> []
      sets != [] -> if one_set?(sets), do: paths(Path.join(folder, hd(sets))), else: []
      length(names) == 1 -> [Path.join(folder, hd(names))]
      true -> []
    end
  rescue
    File.Error -> []
  end

  defp one_set?(names),
    do: names |> Enum.uniq_by(&String.replace(&1, ~r/-\d{5}-of-/, "-of-")) |> length() == 1

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
