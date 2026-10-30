defmodule Macaw.Data.Table.Edge do
  @moduledoc false
  # The row helpers, for any source (spec/01 §1.1): the shapes data arrives in read as
  # rows, a row read by either spelling of a name, and types suggested from whole
  # columns. `Macaw.Data.Table` delegates its row helpers here, and their docs are its;
  # these are the port of visualize's `Visualize.Data.Table`.

  alias Macaw.Data.Schema

  @compile {:no_warn_undefined, [Table, Nx]}

  # -- rows of any source -----------------------------------------------------------------

  # The rows of a source that is not a table, as `Macaw.Data.Table.rows/1` documents.
  def rows([]), do: []
  # A delivery's rows as they are (macaw#185). A map pattern, so this module needs no
  # delivery at compile time.
  def rows(%{__struct__: Macaw.Data.Delivery, rows: rows}), do: Macaw.Data.Table.rows(rows)
  # A map pattern, not `%Nx.Tensor{}`: a struct pattern needs the struct defined at
  # compile time, and a consumer without Nx has none.
  def rows(%{__struct__: Nx.Tensor} = tensor), do: tensor_rows(tensor, Nx.rank(tensor))
  def rows(%_{} = struct), do: struct |> Table.to_rows() |> Enum.to_list()
  def rows(map) when map_size(map) == 0, do: []
  def rows(map) when is_map(map), do: column_rows(Map.to_list(map))

  def rows([first | _] = list) do
    if columns?(list, first), do: column_rows(list), else: list
  end

  # Every key of every row map, in term order. Each row's keys are compared with the row
  # before it, as rows of one shape share them, and only a new shape's keys are added: no
  # row map is merged or built.
  def column_names(rows) do
    {seen, _last} =
      Enum.reduce(rows, {%{}, nil}, fn
        row, {seen, last} when is_map(row) ->
          case Map.keys(row) do
            ^last -> {seen, last}
            keys -> {Enum.reduce(keys, seen, &Map.put(&2, &1, true)), keys}
          end

        _row, acc ->
          acc
      end)

    seen |> Map.keys() |> Enum.sort()
  end

  # -- a time at the edge -----------------------------------------------------------------

  # A time at the edge: a `Date` at midnight UTC, a `NaiveDateTime` taken as UTC, an
  # ISO 8601 string parsed as one of those; anything else as it is, for `new/1` to refuse.
  def to_datetime(%DateTime{} = t), do: t
  def to_datetime(%NaiveDateTime{} = t), do: DateTime.from_naive!(t, "Etc/UTC")
  def to_datetime(%Date{} = d), do: DateTime.new!(d, ~T[00:00:00], "Etc/UTC")

  def to_datetime(string) when is_binary(string) do
    with {:error, _} <- DateTime.from_iso8601(string),
         {:error, _} <- NaiveDateTime.from_iso8601(string),
         {:error, _} <- Date.from_iso8601(string) do
      string
    else
      {:ok, t, _offset} -> t
      {:ok, t} -> to_datetime(t)
    end
  end

  def to_datetime(other), do: other

  # -- names --------------------------------------------------------------------------------

  def named(%{__struct__: Nx.Tensor} = tensor, names) when is_list(names) do
    case {Nx.rank(tensor), length(names)} do
      {1, 1} -> {:ok, %{hd(names) => Nx.to_list(tensor)}}
      {1, n} -> {:error, {:width, n, 1}}
      {2, n} -> named_columns(tensor, names, Nx.axis_size(tensor, 1), n)
      {rank, _n} -> {:error, {:rank, rank}}
    end
  end

  def named([first | _] = rows, names) when is_tuple(first) and is_list(names) do
    if columns?(rows, first), do: {:ok, rows}, else: named_rows(rows, names, length(names))
  end

  def named(source, names) when is_list(names), do: {:ok, source}

  def unnamed?(%{__struct__: Nx.Tensor}), do: true
  def unnamed?([first | _] = rows) when is_tuple(first), do: not columns?(rows, first)
  def unnamed?(_source), do: false

  defp named_rows(rows, names, n) do
    rows
    |> Enum.reduce_while([], fn
      row, acc when is_tuple(row) and tuple_size(row) == n ->
        {:cont, [names |> Enum.zip(Tuple.to_list(row)) |> Map.new() | acc]}

      row, _acc when is_tuple(row) ->
        {:halt, {:error, {:width, n, tuple_size(row)}}}

      row, acc ->
        {:cont, [row | acc]}
    end)
    |> case do
      {:error, _width} = error -> error
      named -> {:ok, Enum.reverse(named)}
    end
  end

  defp named_columns(tensor, names, n, n),
    do: {:ok, names |> Enum.zip(tensor |> Nx.transpose() |> Nx.to_list()) |> Map.new()}

  defp named_columns(_tensor, _names, width, n), do: {:error, {:width, n, width}}

  # -- reading a row --------------------------------------------------------------------------

  def key(row, name) when is_map_key(row, name), do: name

  def key(row, name) when is_atom(name),
    do: if(is_map_key(row, Atom.to_string(name)), do: Atom.to_string(name))

  def key(row, name) when is_binary(name) do
    case Process.get({Macaw.Data.Table, name}) do
      key when is_map_key(row, key) -> key
      _other -> scan(row, name)
    end
  end

  defp scan(row, name) do
    found = Enum.find(Map.keys(row), &(is_atom(&1) and Atom.to_string(&1) == name))
    if found, do: Process.put({Macaw.Data.Table, name}, found)
    found
  end

  # -- types suggested ------------------------------------------------------------------------

  def time_columns(source) do
    rows = rows(source)

    rows
    |> column_names()
    |> Enum.filter(fn name -> temporal_column?(Enum.map(rows, &Map.get(&1, name))) end)
  end

  def column_types(source), do: source |> rows() |> infer()

  defp infer(rows) do
    for name <- column_names(rows),
        type = infer_column(Enum.map(rows, &Map.get(&1, name))),
        type != nil,
        into: %{},
        do: {name, type}
  end

  # One column's type from its values, gaps aside; nil when nothing suggests one.
  def infer_column(values), do: infer_one(Enum.reject(values, &is_nil/1))

  defp infer_one([]), do: nil

  defp infer_one(values) do
    cond do
      Enum.all?(values, &temporal?/1) -> :time
      Enum.all?(values, &is_number/1) -> :number
      Enum.all?(values, &is_binary/1) -> :text
      Enum.all?(values, &Schema.color?/1) -> :color
      Enum.all?(values, &(is_atom(&1) and not is_nil(&1))) -> :category
      true -> nil
    end
  end

  def temporal?(%DateTime{}), do: true
  def temporal?(%Date{}), do: true
  def temporal?(%NaiveDateTime{}), do: true

  def temporal?(string) when is_binary(string) do
    match?({:ok, _, _}, DateTime.from_iso8601(string)) or
      match?({:ok, _}, NaiveDateTime.from_iso8601(string)) or
      match?({:ok, _}, Date.from_iso8601(string))
  end

  def temporal?(_), do: false

  defp temporal_column?(values) do
    Enum.any?(values, &(not is_nil(&1))) and Enum.all?(values, &(is_nil(&1) or temporal?(&1)))
  end

  # -- sources --------------------------------------------------------------------------------

  # A list is columns when every element names an equal-length column.
  defp columns?(list, {name, values}) when is_atom(name) or is_binary(name) do
    n = column_length(values)

    n != nil and
      Enum.all?(list, fn
        {k, v} when is_atom(k) or is_binary(k) -> column_length(v) == n
        _other -> false
      end)
  end

  defp columns?(_list, _first), do: false

  defp column_length(values) when is_list(values), do: length(values)

  defp column_length(%{__struct__: Nx.Tensor} = tensor) do
    if Nx.rank(tensor) == 1, do: Nx.axis_size(tensor, 0)
  end

  defp column_length(_values), do: nil

  defp column_values(%{__struct__: Nx.Tensor} = tensor) do
    if Nx.rank(tensor) == 1, do: Nx.to_list(tensor), else: tensor
  end

  defp column_values(values), do: values

  defp column_rows(pairs) do
    columns = Enum.map(pairs, fn {name, values} -> {name, column_values(values)} end)
    [{_, first} | _] = columns
    n = if is_list(first), do: length(first), else: 0

    Enum.each(columns, fn {name, values} ->
      unless is_list(values) and length(values) == n do
        raise ArgumentError,
              "expected every column to be a list of #{n} values, got #{inspect(name)}: " <>
                inspect(values)
      end
    end)

    names = Enum.map(columns, &elem(&1, 0))

    columns
    |> Enum.map(&elem(&1, 1))
    |> Enum.zip_with(fn values -> names |> Enum.zip(values) |> Map.new() end)
  end

  defp tensor_rows(tensor, 1), do: Nx.to_list(tensor)
  defp tensor_rows(tensor, 2), do: tensor |> Nx.to_list() |> Enum.map(&List.to_tuple/1)

  defp tensor_rows(tensor, rank) do
    raise ArgumentError, "expected a tensor of rank 1 or 2, got rank #{rank}: #{inspect(tensor)}"
  end
end
