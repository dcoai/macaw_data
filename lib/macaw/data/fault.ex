defmodule Macaw.Data.Fault do
  @moduledoc """
  The library's one fault-to-sentence formatter (spec/00 §5): an `{:error, reason}`'s
  term as the words a person reads.

  A reason is a list of faults, `{path, reason}` each, or one bare reason. A fault reads
  `path: words`, its path as `Macaw.Layers.Fault.format_path/2` writes it with the empty
  path named by `root:`, and the faults of a list are joined by `"; "`:

      iex> Macaw.Data.Fault.sentence([{[:temp], {:length, 3}}, {[:at, 1], {:type, :time}}])
      "temp: must hold 3 values, as the first column does; at[1]: must be a time: a DateTime, a NaiveDateTime or a Date"
      iex> Macaw.Data.Fault.sentence([{[], {:rank, 3}}], root: "source")
      "source: is a tensor of rank 3; a source's tensor has rank 1 or 2"

  The words are the library's reason vocabulary (`words/1`), then the kernel's
  (`Macaw.Layers.Fault`), so a reason reads one way whichever function answered it. A
  module with words of its own gives them as `words:`, tried first. A reason none of them
  words reads as its term, never dropped.
  """

  alias Macaw.Layers.Fault, as: LayersFault

  @typedoc "A fault: where, and why."
  @type t :: {LayersFault.path(), term()}

  @typedoc "`sentence/2`'s options."
  @type option :: {:root, String.t()} | {:words, (term() -> String.t() | nil)}

  @doc """
  An `{:error, reason}`'s term as one sentence: each fault of a list as `path: words`,
  joined by `"; "`, or a bare reason's words.

  Options:
  - `root:` the name of the empty path, `"value"` by default;
  - `words:` a module's own words for a reason, `nil` for one it does not word.
  """
  @spec sentence(term(), [option()]) :: String.t()
  def sentence(reason, opts \\ [])

  def sentence([_ | _] = faults, opts) do
    if Enum.all?(faults, &fault?/1),
      do: Enum.map_join(faults, "; ", &format(&1, opts)),
      else: reason_words(faults, opts)
  end

  def sentence(reason, opts) do
    if fault?(reason), do: format(reason, opts), else: reason_words(reason, opts)
  end

  @doc "One fault as `path: words`, with `sentence/2`'s options."
  @spec format(t(), [option()]) :: String.t()
  def format({path, reason}, opts \\ []) do
    "#{LayersFault.format_path(Enum.map(path, &step/1), root: Keyword.get(opts, :root, "value"))}: " <>
      reason_words(reason, opts)
  end

  # A module in a path reads as Elixir writes it, `String`, not `Elixir.String`.
  defp step(atom) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> _ -> inspect(atom)
      _other -> atom
    end
  end

  defp step(key) when is_binary(key) or is_integer(key), do: key
  # A key of a caller's term that is neither, a reference or a tuple, read as Elixir writes it.
  defp step(other), do: inspect(other)

  @doc """
  The words of a reason in the library's vocabulary, `nil` for a reason it does not word.

      iex> Macaw.Data.Fault.words({:type, :keyword})
      "must be a keyword list"
      iex> Macaw.Data.Fault.words(:no_such_reason)
      nil
  """
  @spec words(term()) :: String.t() | nil
  def words(:required), do: "is required"
  def words(:unknown_key), do: "is not a key it takes"
  def words(:duplicate), do: "is given twice"
  def words({:duplicate, spelling}), do: "names #{inspect(spelling)} again: a field is named once"

  def words(:not_data),
    do: "is not data: a function, a PID, a reference or a port has no table form"

  def words(:overflow), do: "sums beyond a float's range"
  def words({:reads, :number}), do: "must read a number"

  def words({:length, n}), do: "must hold #{n} values, as the first column does"
  def words({:rank, rank}), do: "is a tensor of rank #{rank}; a source's tensor has rank 1 or 2"

  def words({:width, n, width}),
    do: "must name each of a row's #{width} values: #{n} names are given"

  def words({:unsorted, i}), do: "is out of the window field's order at row #{i}"
  def words({:enum, allowed}) when is_list(allowed), do: "must be one of #{list(allowed)}"
  def words(:unknown_path), do: "is not a path the engine defines"
  def words({:unknown, :reducer, name}), do: "#{inspect(name)} is not a reducer the registry has"
  def words({:unknown_field, name}), do: "#{inspect(name)} is not a field the schema describes"
  def words({:unknown_column, name}), do: "#{inspect(name)} is not a column of the table"
  def words({:invalid_for, type}), do: "is a #{inspect(type)} field, which has no order"

  def words(:no_window_field),
    do: "needs a window field: the schema describes none"

  def words(:not_a_function_module),
    do: "is not a module of derived-source functions: it has no __derived__/0"

  def words({:defined_twice, module, other}),
    do: "is defined by both #{inspect(module)} and #{inspect(other)}"

  def words({:type, type}) do
    case type_words(type) do
      nil -> nil
      words -> "must be " <> words
    end
  end

  def words(_reason), do: nil

  defp type_words(:keyword), do: "a keyword list"
  defp type_words(:rows), do: "rows: a list of maps, or a list of tuples"

  defp type_words(:source),
    do: "a source: a table, rows, a map of columns, a tensor or a Table.Reader source"

  defp type_words(:column), do: "a column: a list of values, or a rank-1 tensor"
  defp type_words(:column_spec), do: "a column: {name, type, values}"
  defp type_words(:table), do: "a Macaw.Data.Table"
  defp type_words(:time), do: "a time: a DateTime, a NaiveDateTime or a Date"
  defp type_words(:instant), do: "an instant: a time, or a number on the window field's scale"
  defp type_words(:number), do: "a number"
  defp type_words(:category), do: "a category: an atom or a string"
  defp type_words(:text), do: "text: a string"
  defp type_words(:color), do: "a data color, a color term"
  defp type_words(:point), do: "a point: {x, y}, two numbers"
  defp type_words(:term), do: "data: no function, PID, reference or port"
  defp type_words(:window), do: "a window: {from, to}, from not after to"
  defp type_words(:box), do: "a box: %{x: [min, max], y: [min, max]}"
  defp type_words(:region), do: "a region: a map from a field to its [min, max]"
  defp type_words(:range), do: "a range: [min, max]"
  defp type_words(:reference), do: "a reference"
  defp type_words(:order), do: "an order: a list of {field, :asc | :desc}, each field a name"
  defp type_words(:duration), do: "a Duration"
  defp type_words(:integer), do: "an integer"
  defp type_words(:cache), do: "a Macaw.Data.Schema.Cache"
  defp type_words(:lateness), do: "a lateness: a number or a Duration"

  defp type_words(:chunk_span),
    do: "a chunk span: a positive number, or a positive Duration of fixed length"

  defp type_words(:schema), do: "a Macaw.Data.Schema"
  defp type_words(:registry), do: "an operations registry"
  defp type_words(:modules), do: "a list of modules"
  defp type_words(:names), do: "names: a list of column names"
  defp type_words(_type), do: nil

  # A module's own words, then the library's, then the kernel's; else the term itself.
  defp reason_words(reason, opts) do
    own = Keyword.get(opts, :words, fn _reason -> nil end)

    own.(reason) || words(reason) ||
      LayersFault.format({[], reason}, root: "") |> String.replace_prefix(": ", "")
  end

  defp fault?({path, _reason}) when is_list(path), do: true
  defp fault?(_other), do: false

  defp list(allowed), do: Enum.map_join(allowed, ", ", &inspect/1)
end
