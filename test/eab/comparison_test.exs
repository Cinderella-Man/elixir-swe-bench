defmodule Eab.ComparisonTest do
  use ExUnit.Case, async: true
  alias Eab.Comparison

  test "comparison rejects mixed policies, accepts series siblings and keeps outcomes distinct" do
    run = %{
      "id" => "first",
      "release_id" => "frozen",
      "settings" => %{"seed" => 101},
      "cases" => ~w(a b),
      "status" => "completed",
      "model" => %{"model" => "model-a"},
      "attempts" => %{
        "a" => %{"status" => "completed", "grade" => %{"passed" => true}},
        "b" => %{"status" => "completed", "grade" => %{"passed" => false}}
      }
    }

    other =
      run
      |> Map.put("id", "other")
      |> Map.put("status", "error")
      |> put_in(["attempts", "b"], %{"status" => "error"})

    comparison = Comparison.build([run, other])
    assert Enum.map(comparison["runs"], & &1["score"]["score_percent"]) == [50.0, nil]
    assert Enum.at(comparison["cases"], 1)["outcomes"] == ["Failed", "Evaluation error"]

    # Runs of one series differ in seed and may differ in benchmark code (release ID).
    sibling = other |> Map.put("release_id", "another") |> put_in(["settings", "seed"], 102)
    assert Enum.map(Comparison.build([run, sibling])["runs"], & &1["seed"]) == [101, 102]

    for changed <- [
          Map.put(other, "release_id", nil),
          Map.put(other, "cases", ~w(b a)),
          put_in(other, ["settings", "reasoning_effort"], "off"),
          Map.put(other, "protocol", %{"fixtures" => %{"a" => %{"case.json" => "changed"}}})
        ],
        do: assert_raise(RuntimeError, fn -> Comparison.build([run, changed]) end)
  end
end
