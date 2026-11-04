defmodule Macaw.Data.Table.Edge do
  @moduledoc false
  # The row helpers, for any source (spec/01 §1.1): the shapes data arrives in read as
  # rows, a row read by either spelling of a name, and types suggested from whole
  # columns. `Macaw.Data.Table` delegates its row helpers here, and their docs are its;
  # these are the port of visualize's `Visualize.Data.Table`.

  alias Macaw.Data.Schema

  @compile {:no_warn_undefined, [Table, Table.Reader, Nx]}

  # -- rows of any source -----------------------------------------------------------------

  # Whether a source is of a shape `rows/1` reads, as `Macaw.Data.Table.source/1`
  # documents: `:ok`, or its faults. A row list's rows are all maps or all tuples; a column
  # map's every column a list (or a rank-1 tensor) of the first's length; a tensor of rank
  # 1 or 2; any other struct a `Table.Reader` source.
  def source(%Macaw.Data.Table{}), do: :ok
  def source(%{__struct__: Macaw.Data.Delivery, rows: rows}), do: source(rows)
  def source([]), do: :ok

  def source(list) when is_list(list) do
    if Enum.all?(list, &is_map/1) or Enum.all?(list, &is_tuple/1),
      do: :ok,
      else: {:error, [{[], {:type, :rows}}]}
  end

  def source(%{__struct__: Nx.Tensor} = tensor) do
    case Nx.rank(tensor) do
      rank when rank in [1, 2] -> :ok
      rank -> {:error, [{[], {:rank, rank}}]}
    end
  end

  def source(%_{} = struct) do
    if Code.ensure_loaded?(Table.Reader) and Table.Reader.impl_for(struct) != nil,
      do: :ok,
      else: {:error, [{[], {:type, :source}}]}
  end

  def source(map) when map_size(map) == 0, do: :ok

  def source(map) when is_map(map) do
    [{_, first} | _] =
      columns = Enum.map(map, fn {name, values} -> {name, column_length(values)} end)

    n = first || 0

    faults =
      for {name, length} <- columns, length != n do
        if length == nil, do: {[name], {:type, :column}}, else: {[name], {:length, n}}
      end

    if faults == [], do: :ok, else: {:error, faults}
  end

  def source(_other), do: {:error, [{[], {:type, :source}}]}

  # The rows of a source that is not a table, as `Macaw.Data.Table.rows/1` documents:
  # `{:ok, rows}`, or `source/1`'s faults. A delivery's rows as they are (macaw#185), read
  # by `Table.rows/1`; a map pattern, so this module needs no delivery at compile time.
  def rows(%{__struct__: Macaw.Data.Delivery, rows: rows}), do: Macaw.Data.Table.rows(rows)

  def rows(source) do
    with :ok <- source(source), do: {:ok, read(source)}
  end

  # A source `source/1` accepts, read: a column's length and a tensor's rank are checked.
  defp read([]), do: []
  # A map pattern, not `%Nx.Tensor{}`: a struct pattern needs the struct defined at
  # compile time, and a consumer without Nx has none.
  defp read(%{__struct__: Nx.Tensor} = tensor), do: tensor_rows(tensor, Nx.rank(tensor))
  defp read(%_{} = struct), do: struct |> Table.to_rows() |> Enum.to_list()
  defp read(map) when map_size(map) == 0, do: []
  defp read(map) when is_map(map), do: column_rows(Map.to_list(map))

  defp read([first | _] = list) do
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

  # A name of neither spelling (a row map's keys are its own): only itself, above.
  def key(_row, _name), do: nil

  defp scan(row, name) do
    found = Enum.find(Map.keys(row), &(is_atom(&1) and Atom.to_string(&1) == name))
    if found, do: Process.put({Macaw.Data.Table, name}, found)
    found
  end

  # -- types suggested ------------------------------------------------------------------------

  # Both read a source through `Table.rows/1`: `{:ok, value}`, or the faults `source/1`
  # answers for a source of no shape it reads (macaw_data#161).
  def time_columns(source) do
    with {:ok, rows} <- Macaw.Data.Table.rows(source) do
      {:ok,
       rows
       |> column_names()
       |> Enum.filter(fn name -> temporal_column?(Enum.map(rows, &Map.get(&1, name))) end)}
    end
  end

  def column_types(source) do
    with {:ok, rows} <- Macaw.Data.Table.rows(source), do: {:ok, infer(rows)}
  end

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

  # Columns `source/1` (or `columns?/2`) found to be lists, or rank-1 tensors, of one length.
  defp column_rows(pairs) do
    names = Enum.map(pairs, &elem(&1, 0))

    pairs
    |> Enum.map(fn {_name, values} -> column_values(values) end)
    |> Enum.zip_with(fn values -> names |> Enum.zip(values) |> Map.new() end)
  end

  # A tensor `source/1` found of rank 1 or 2.
  defp tensor_rows(tensor, 1), do: Nx.to_list(tensor)
  defp tensor_rows(tensor, 2), do: tensor |> Nx.to_list() |> Enum.map(&List.to_tuple/1)
end
