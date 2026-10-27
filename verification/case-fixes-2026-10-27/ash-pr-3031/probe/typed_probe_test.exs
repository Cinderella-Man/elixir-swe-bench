defmodule Ash.Benchmark.TypedProbeTest do
  use ExUnit.Case, async: false
  require Ash.Query
  import Ash.Expr

  defmodule NormalizedInteger do
    use Ash.Type
    def storage_type(_), do: :integer
    def cast_stored(value, _), do: {:ok, value}
    def dump_to_native(value, _), do: {:ok, value}
    def cast_input(value, _) when is_integer(value), do: {:ok, value + 1}
    def cast_input(_, _), do: :error
    def apply_constraints(value, _), do: {:ok, value * 2}
  end

  defmodule Item do
    use Ash.Resource, domain: Ash.Test.Domain, data_layer: Ash.DataLayer.Ets
    ets do
      private? true
    end
    actions do
      defaults [:read, create: :*]
    end
    attributes do
      uuid_primary_key :id
      attribute :number, NormalizedInteger, public?: true
      attribute :enabled, :boolean, public?: true
    end
    calculations do
      calculate :at_least, :boolean, expr(number >= ^arg(:value) and ^arg(:other)) do
        public? true
        argument :value, NormalizedInteger, allow_nil?: false
        argument :other, :boolean, allow_expr?: true, allow_nil?: false
      end
      calculate :only_value, :boolean, expr(number >= ^arg(:value)) do
        public? true
        argument :value, NormalizedInteger, allow_nil?: false
      end
      calculate :echo, :integer, expr(^arg(:value)) do
        public? true
        argument :value, NormalizedInteger, allow_nil?: false
      end
      calculate :echo_beside, :integer, expr(if ^arg(:other), do: ^arg(:value), else: 0) do
        public? true
        argument :value, NormalizedInteger, allow_nil?: false
        argument :other, :boolean, allow_expr?: true, allow_nil?: false
      end
    end
  end

  setup do
    item = Item |> Ash.Changeset.for_create(:create, %{number: 2, enabled: true}) |> Ash.create!()
    assert item.number == 6
    %{item: item}
  end

  test "literal only, two arguments: load", %{item: item} do
    assert %{at_least: true} = Ash.load!(item, at_least: %{value: 2, other: true})
  end

  test "literal only, two arguments: filter" do
    assert [_] = Item |> Ash.Query.filter(^%{at_least: %{input: %{value: 2, other: true}, eq: true}}) |> Ash.read!()
  end

  test "single literal argument: load", %{item: item} do
    assert %{only_value: true} = Ash.load!(item, only_value: %{value: 2})
  end

  test "single literal argument: filter" do
    assert [_] = Item |> Ash.Query.filter(^%{only_value: %{input: %{value: 2}, eq: true}}) |> Ash.read!()
  end

  test "beside an expression: load", %{item: item} do
    assert %{at_least: true} = Ash.load!(item, at_least: %{value: 2, other: expr(enabled)})
  end

  test "beside an expression: filter" do
    assert [_] = Item |> Ash.Query.filter(^%{at_least: %{input: %{value: 2, other: expr(enabled)}, eq: true}}) |> Ash.read!()
  end

  test "echo keeps the normalized literal", %{item: item} do
    assert %{echo: 6} = Ash.load!(item, echo: %{value: 2})
    assert %{echo_beside: 6} = Ash.load!(item, echo_beside: %{value: 2, other: true})
    assert %{echo_beside: 6} = Ash.load!(item, echo_beside: %{value: 2, other: expr(enabled)})
  end

  test "value 3 is normalized to 8 and must not match 6", %{item: item} do
    assert %{only_value: false} = Ash.load!(item, only_value: %{value: 3})
    assert %{at_least: false} = Ash.load!(item, at_least: %{value: 3, other: expr(enabled)})
    assert %{at_least: false} = Ash.load!(item, at_least: %{value: 3, other: true})
  end
end
