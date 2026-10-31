defmodule Macaw.Data.Operations.LadderPackedTest do
  # A ladder piece packed into one binary (spec/04 §4.5.3; macaw_data#38, #46): read back,
  # it is the walk's segments term for term, of either number type, mixed or past int64.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.Operations.Transforms.Ladder.Packed
  alias Macaw.Data.Test.Gen

  @int64_max 0x7FFF_FFFF_FFFF_FFFF

  defp number(:int), do: integer(-1_000_000..1_000_000)
  defp number(:float), do: Gen.float(min: -1.0e12, max: 1.0e12)
  defp number(:big), do: member_of([@int64_max + 1, -@int64_max - 2, 2 ** 80])
  defp number(:mixed), do: one_of([number(:int), number(:float)])

  defp point(st, yt), do: tuple({integer(0..9_000), number(st), number(yt)})

  defp bucket(st, yt) do
    tuple(
      {integer(-10_000..10_000),
       tuple({point(st, yt), point(st, yt), point(st, yt), point(st, yt)})}
    )
  end

  defp segments(st, yt) do
    list_of(
      one_of([
        tuple({constant(:gap), integer(0..9_000)}),
        tuple({constant(:run), list_of(bucket(st, yt), min_length: 1, max_length: 6)})
      ]),
      max_length: 8
    )
  end

  # The exact type of every number in a term, so a float read back as an integer, or -0.0
  # as 0.0, is told apart.
  defp exact(term) when is_tuple(term), do: term |> Tuple.to_list() |> exact() |> List.to_tuple()
  defp exact(list) when is_list(list), do: Enum.map(list, &exact/1)
  defp exact(f) when is_float(f), do: {:float, <<f::float-64>>}
  defp exact(other), do: other

  describe "a packed piece" do
    @tag verifies: "operations-ladder-packed-read"
    property "read back is the segments, term for term, and read as a view's carries that view" do
      check all(
              {st, yt} <-
                member_of([
                  {:int, :int},
                  {:int, :float},
                  {:float, :int},
                  {:float, :float},
                  {:mixed, :float},
                  {:int, :mixed},
                  {:big, :float}
                ]),
              segments <- segments(st, yt),
              v <- integer(0..40),
              max_runs: 300
            ) do
        piece = Packed.pack(segments)
        assert is_binary(piece)
        assert exact(Packed.unpack(piece)) == exact(segments)

        located =
          for segment <- segments do
            case segment do
              {:gap, row} -> {:gap, {v, row}}
              {:run, run} -> {:run, for({b, s} <- run, do: {b, {v, s}})}
            end
          end

        assert exact(Packed.located(piece, v)) == exact(located)
      end
    end

    @tag verifies: "operations-ladder-packed-read"
    test "is fixed-width where its points share a type, and kept as a term where they don't" do
      p = {3, 1.5, 2}
      run = {:run, [{7, {p, p, p, p}}]}
      packed = Packed.pack([{:gap, 0}, run])

      assert <<1, 1, 0, 0, 2::little-32, _heads::binary-size(16), _bucket::binary-size(88)>> =
               packed

      assert <<1, 0, 0, 0, 0::little-32>> = Packed.pack([])
      assert <<1, 0, 0, 0, 1::little-32, 0, 0::24, 5::little-32>> = Packed.pack([{:gap, 5}])

      q = {4, 2, 2}
      mixed = [{:run, [{7, {p, q, p, q}}]}]
      assert <<2, _::binary>> = Packed.pack(mixed)
      assert Packed.unpack(Packed.pack(mixed)) === mixed
    end
  end
end
