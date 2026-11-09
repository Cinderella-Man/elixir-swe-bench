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
