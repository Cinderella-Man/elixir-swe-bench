defmodule Eab.MemoryCollector.Weights do
  @moduledoc false

  # Count the exact GGUF file or its complete, numbered shard set, or the files a Strata
  # pack lists. Optional metadata must not prevent memory collection when files are unavailable.
  def read(path) when is_binary(path) do
    files = files(path)

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
        header = header(hd(files))
        {creator, gguf} = Map.pop(header, "general.quantized_by")
        found = if creator, do: Map.put(found, "quantized_by", creator), else: found
        if gguf != %{}, do: Map.put(found, "gguf", gguf), else: found
      end
    end
  end

  def read(_), do: nil

  @doc "The weight files a served path stands for, as absolute paths in shard order."
  def files(path) when is_binary(path),
    do: if(File.dir?(path), do: pack(path), else: paths(path))

  def files(_), do: []

  # Who made the quantization and which release and calibration it is, as the GGUF names
  # them: general.quantized_by ("Unsloth"), general.version, quantize.imatrix.dataset and so
  # on. Makers often write these after the tokenizer's arrays, so the read covers the key/value
  # section of a large vocabulary (about 12 MB for 248k tokens), not the weights. A header
  # that does not parse names nothing.
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
  # Release, provenance and calibration keys worth recording; arrays, tokenizer data and
  # anything else are skipped.
  @keys ~w(general.quantized_by general.name general.basename general.finetune general.version
    general.size_label general.organization general.architecture general.license general.url
    general.repo_url general.source.url general.source.huggingface.repository
    general.base_model.count general.base_model.0.name general.base_model.0.organization
    general.base_model.0.version general.base_model.0.repo_url general.file_type
    general.quantization_version quantize.imatrix.file quantize.imatrix.dataset
    quantize.imatrix.entries_count quantize.imatrix.chunks_count)
  # Calibration files are named by their basename only; the maker's paths are not kept.
  @basenames ~w(quantize.imatrix.file quantize.imatrix.dataset)

  def keys, do: @keys

  def quantized_by(file), do: header(file)["general.quantized_by"]

  def header(file) do
    case File.open(file, [:read, :binary], &IO.binread(&1, @header_bytes)) do
      {:ok, <<"GGUF", version::little-32, _tensors::little-64, count::little-64, rest::binary>>}
      when version in 2..3 ->
        entries(rest, min(count, 4096), %{})

      _ ->
        %{}
    end
  end

  defp entries(
         <<size::little-64, key::binary-size(size), type::little-32, rest::binary>>,
         left,
         acc
       )
       when left > 0 do
    case value(type, rest) do
      {value, rest} ->
        entries(rest, left - 1, keep(acc, key, value))

      nil ->
        acc
    end
  end

  defp entries(_, _, acc), do: acc

  defp keep(acc, key, value) when key in @keys and is_binary(value) do
    if String.valid?(value) do
      value = String.trim(value)
      value = if key in @basenames, do: Path.basename(value), else: value
      if byte_size(value) in 1..200, do: Map.put(acc, key, value), else: acc
    else
      acc
    end
  end

  defp keep(acc, key, value) when key in @keys and is_integer(value),
    do: Map.put(acc, key, value)

  defp keep(acc, _, _), do: acc

  @integers %{0 => 8, 2 => 16, 4 => 32, 10 => 64}
  @signed %{1 => 8, 3 => 16, 5 => 32, 11 => 64}

  defp value(type, rest) when is_map_key(@integers, type) do
    bits = @integers[type]

    case rest do
      <<n::little-unsigned-size(^bits), rest::binary>> -> {n, rest}
      _ -> nil
    end
  end

  defp value(type, rest) when is_map_key(@signed, type) do
    bits = @signed[type]

    case rest do
      <<n::little-signed-size(^bits), rest::binary>> -> {n, rest}
      _ -> nil
    end
  end

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

  @chunk 8 * 1024 * 1024
  @stat ~w(size inode mtime ctime)

  @doc """
  The sha256 of each file, in order. A file whose path, size, inode and modification and
  change times match the cache is not read again; the cache is saved after each file, so an
  interrupted pass keeps what it finished. A file changed after `started_at` (Unix seconds,
  the model server's start) may not be what the server loaded, so then nothing is hashed.
  """
  def hashes(paths, started_at, cache_file) do
    stats = Enum.map(paths, &{&1, File.stat!(&1, time: :posix)})

    if is_integer(started_at) and
         Enum.any?(stats, fn {_, stat} -> max(stat.ctime, stat.mtime) > started_at end) do
      {:changed, "A weight file changed after the model server started"}
    else
      {files, _} =
        Enum.map_reduce(stats, read_cache(cache_file), fn {path, stat}, cache ->
          key = %{
            "size" => stat.size,
            "inode" => stat.inode,
            "mtime" => stat.mtime,
            "ctime" => stat.ctime
          }

          case cache[path] do
            %{"sha256" => sha} = entry when is_binary(sha) and map_size(entry) == 5 ->
              if Map.take(entry, @stat) == key,
                do: {file(path, stat, sha), cache},
                else: hash_and_save(path, stat, key, cache, cache_file)

            _ ->
              hash_and_save(path, stat, key, cache, cache_file)
          end
        end)

      {:ok, files}
    end
  end

  defp file(path, stat, sha),
    do: %{"name" => Path.basename(path), "size_bytes" => stat.size, "sha256" => sha}

  defp hash_and_save(path, stat, key, cache, cache_file) do
    sha = digest(path)
    # Entries for files that are gone are dropped, so the cache stays the size of the library.
    cache =
      cache
      |> Map.filter(fn {other, _} -> other == path or File.regular?(other) end)
      |> Map.put(path, Map.put(key, "sha256", sha))

    write_cache(cache_file, cache)
    {file(path, stat, sha), cache}
  end

  def digest(path) do
    File.open!(path, [:read, :binary, :raw], fn fd ->
      :file.advise(fd, 0, 0, :sequential)
      digest_loop(fd, :crypto.hash_init(:sha256))
    end)
  end

  defp digest_loop(fd, context) do
    case :file.read(fd, @chunk) do
      {:ok, data} -> digest_loop(fd, :crypto.hash_update(context, data))
      :eof -> context |> :crypto.hash_final() |> Base.encode16(case: :lower)
      {:error, reason} -> raise File.Error, reason: reason, action: "read", path: "weight file"
    end
  end

  defp read_cache(file) do
    with {:ok, body} <- File.read(file),
         {:ok, %{} = cache} <- JSON.decode(body) do
      cache
    else
      _ -> %{}
    end
  end

  defp write_cache(file, cache) do
    File.mkdir_p!(Path.dirname(file))
    temp = file <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(temp, JSON.encode!(cache))
    File.chmod!(temp, 0o600)
    File.rename!(temp, file)
  rescue
    # A read-only cache only costs a later run the same reading.
    _ -> :ok
  end

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
