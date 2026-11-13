defmodule Macaw.Data.Test.GeneratorsTest do
  # macaw_data#290: no generator in the suite asks StreamData for unique elements from a
  # finite list. `map_of/3` and `uniq_list_of/2` retry a duplicate at most 10 times in a
  # row and then raise, so over a few keys (`member_of([:a, :b])` for a map of two) a
  # property fails now and then and tests nothing. `Macaw.Data.Test.Gen.map_of/3` and
  # `two_of/1` draw the same without retrying. Read on the syntax tree, so a comment or a
  # string is no call.
  use ExUnit.Case, async: true

  @retrying [:map_of, :uniq_list_of]

  # Every call of `map_of`/`uniq_list_of`, bare or StreamData's, whose first argument
  # draws from `member_of`, as `{file, line}`.
  def offenders(files) do
    for file <- files,
        {:ok, ast} = Code.string_to_quoted(File.read!(file), file: file, columns: false),
        line <- calls(ast),
        do: {Path.relative_to_cwd(file), line}
  end

  defp calls(ast) do
    {_, lines} =
      Macro.prewalk(ast, [], fn
        {name, meta, [first | _]} = node, acc when name in @retrying ->
          {node, if(member_of?(first), do: [meta[:line] | acc], else: acc)}

        {{:., _, [{:__aliases__, _, [:StreamData]}, name]}, meta, [first | _]} = node, acc
        when name in @retrying ->
          {node, if(member_of?(first), do: [meta[:line] | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(lines)
  end

  defp member_of?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:member_of, _, args} = node, _ when is_list(args) -> {node, true}
        {{:., _, [_, :member_of]}, _, args} = node, _ when is_list(args) -> {node, true}
        node, found -> {node, found}
      end)

    found
  end

  test "no generator asks for unique elements drawn from a finite list" do
    files = Path.wildcard("test/**/*.{ex,exs}")
    assert length(files) > 100
    assert offenders(files) == []
  end

  @tag :tmp_dir
  test "the check finds each form and passes Gen's", %{tmp_dir: dir} do
    bad = Path.join(dir, "bad_test.exs")

    File.write!(bad, """
    map_of(member_of([:a, :b]), integer(), max_length: 2)
    StreamData.uniq_list_of(StreamData.member_of(~w(x y)), length: 2)
    map_of(one_of([member_of(keys), leaf()]), value(), max_length: 3)
    # map_of(member_of([:a]), integer())
    """)

    good = Path.join(dir, "good_test.exs")

    File.write!(good, """
    Gen.map_of(member_of([:a, :b]), integer(), max_length: 2)
    map_of(name(), member_of([:x, :y]), max_length: 3)
    "map_of(member_of([:a]))"
    """)

    assert offenders([bad]) == [
             {Path.relative_to_cwd(bad), 1},
             {Path.relative_to_cwd(bad), 2},
             {Path.relative_to_cwd(bad), 3}
           ]

    assert offenders([good]) == []
  end
end
