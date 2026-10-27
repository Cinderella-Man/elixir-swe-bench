defmodule Eab.Measurement do
  @moduledoc """
  Elapsed case time from Pi startup through completion, before independent grading.
  Recorded only when a run works on one attempt at a time (ADR 0014).
  """

  @parallel "Not measured: the run worked on several attempts at once"

  def start(measure? \\ true)

  def start(true) do
    clock = Application.get_env(:eab, :measurement_clock, &clock/0)
    %{clock: clock, started: clock.()}
  end

  def start(false), do: :parallel

  def finish(:parallel), do: %{"not_measured" => @parallel}

  def finish(measurement) do
    %{"attempt_ms" => measurement.clock.() - measurement.started}
  end

  defp clock, do: System.monotonic_time(:millisecond)

  def label(%{"attempt_ms" => ms}) when is_integer(ms),
    do: "#{Float.round(ms / 1000, 3)} s"

  def label(%{"not_measured" => reason}) when is_binary(reason), do: reason
  def label(_), do: "Not measured"
end
