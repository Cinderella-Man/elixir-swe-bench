defmodule Eab.MemoryCollector.CLI do
  @moduledoc "NDJSON over stdin/stdout; no credentials or raw HTTP responses are emitted."
  @interval 1_000

  def main do
    :logger.set_primary_config(:level, :emergency)

    case read_line(16_384) do
      :eof ->
        :ok

      body ->
        request = JSON.decode!(body)

        if request["mode"] == "snapshot",
          do: emit(Eab.MemoryCollector.snapshot(request)),
          else: stream(request)
    end
  rescue
    error ->
      message =
        if is_struct(error, Eab.MemoryCollector.Error),
          do: Exception.message(error),
          else: "Memory counter collection failed"

      emit(%{
        "type" => "error",
        "at" => now(),
        "error" => inspect(error.__struct__),
        "message" => message
      })

      System.halt(1)
  end

  defp stream(request) do
    state = Eab.MemoryCollector.open(request)
    identity = Eab.MemoryCollector.identity(state)
    {sample, state} = Eab.MemoryCollector.sample(state)
    emit(%{"type" => "ready", "identity" => identity, "interval_ms" => @interval})
    emit(sample)
    parent = self()
    # Older benchmarks do not ask for hashes and would not understand the event.
    if request["hash_weights"] == true, do: Eab.MemoryCollector.hash_weights(state, parent)

    spawn_link(fn ->
      IO.binread(:stdio, 1)
      send(parent, :stop)
    end)

    loop(state, System.monotonic_time(:millisecond) + @interval)
  end

  defp loop(state, deadline) do
    receive do
      {:weights, event} ->
        emit(event)
        loop(state, deadline)

      :stop ->
        {sample, _} = Eab.MemoryCollector.sample(state)
        emit(sample)
        emit(%{"type" => "stopped", "at" => now()})
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        {sample, state} = Eab.MemoryCollector.sample(state)
        emit(sample)
        loop(state, max(deadline + @interval, System.monotonic_time(:millisecond)))
    end
  end

  defp read_line(remaining, acc \\ [])
  defp read_line(0, _), do: raise(Eab.MemoryCollector.Error, "Oversized request")

  defp read_line(remaining, acc) do
    case IO.binread(:stdio, 1) do
      :eof -> :eof
      "\n" -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      byte when is_binary(byte) -> read_line(remaining - 1, [byte | acc])
      _ -> raise "Collector input closed"
    end
  end

  defp emit(value), do: IO.binwrite(:stdio, JSON.encode!(value) <> "\n")
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
