defmodule Macaw.Data.RowsTwinCallersTest do
  @moduledoc """
  Every call in lib/ of a twin that reads a source's rows, `Table.rows!/1`,
  `Delivery.rows!/1` and `Delivery.named_rows!/1`, is reviewed (spec/00 §5, macaw_data#161).
  The raise guard reads only literal raise sites, so a non-`!` function that reaches a
  `!` twin with a caller's source raises unseen: #161's `column_types/1`, `time_columns/1`
  and `Stack.generate/2` did. Here each call site is held to a list that says why its
  argument can't be refused, so a new one fails until it is read and reasoned.
  """
  use ExUnit.Case, async: true

  @twins [:rows!, :named_rows!]

  # `{module, function, arity, twin}` => why its argument always answers.
  @reviewed %{
    {Macaw.Data.Derived.Engine, :subject, 1, :rows!} =>
      "a delivery Delivery.new/2 built, its rows' shape checked; neither a table nor a row list",
    {Macaw.Data.Derived.Engine, :input_rows, 1, :rows!} => "a %Table{}: a table always answers",
    {Macaw.Data.Source.Push, :reheld, 3, :rows!} => "the held %Table{}: a table always answers"
  }

  # Every call of a twin in `source`: `{module, function, arity, twin}`, module-nested.
  defp calls(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    walk(ast, nil, nil, [])
  end

  defp walk({:defmodule, _, [alias, [do: body]]}, outer, _def, acc),
    do: walk(body, nest(outer, alias), nil, acc)

  defp walk({kind, _, [head | rest]}, module, _def, acc) when kind in [:def, :defp] do
    {name, arity} = head(head)
    walk(rest, module, {name, arity}, acc)
  end

  defp walk({{:., _, [_target, twin]}, _, args}, module, {name, arity}, acc)
       when twin in @twins do
    walk(args, module, {name, arity}, [{module, name, arity, twin} | acc])
  end

  defp walk({_, _, args}, module, def, acc) when is_list(args), do: walk(args, module, def, acc)
  defp walk({left, right}, module, def, acc), do: walk([left, right], module, def, acc)

  defp walk(list, module, def, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, module, def, &2))

  defp walk(_leaf, _module, _def, acc), do: acc

  defp head({:when, _, [head | _]}), do: head(head)
  defp head({name, _, args}) when is_list(args), do: {name, length(args)}
  defp head({name, _, _context}), do: {name, 0}

  defp nest(nil, {:__aliases__, _, parts}), do: Module.concat(parts)
  defp nest(outer, {:__aliases__, _, parts}), do: Module.concat([outer | parts])

  @tag verifies: "data-errors-rows-twins"
  test "every call of a rows twin in lib/ is reviewed, and every reviewed call is there" do
    found =
      for file <- Path.wildcard("lib/**/*.ex"),
          call <- calls(File.read!(file)),
          into: MapSet.new(),
          do: call

    reviewed = @reviewed |> Map.keys() |> MapSet.new()

    assert MapSet.difference(found, reviewed) == MapSet.new(),
           "a call of a rows twin no one has reviewed: answer the value twin's faults, or add it with why its argument can't be refused"

    assert MapSet.difference(reviewed, found) == MapSet.new(), "a reviewed call that is gone"
  end

  @tag verifies: "data-errors-rows-twins"
  test "a call in a def, a pipe into one and a nested module are all found" do
    source = """
    defmodule A do
      def read(x), do: Macaw.Data.Table.rows!(x)
      defmodule B do
        defp piped(x, _y) when is_map(x), do: x |> Delivery.named_rows!() |> length()
      end
    end
    """

    assert Enum.sort(calls(source)) == [{A, :read, 1, :rows!}, {A.B, :piped, 2, :named_rows!}]
  end
end
