defmodule Macaw.Data.Monitor.Given do
  @moduledoc false
  # What a monitor's caller gives it, judged (spec/01 §6.3, spec/00 §5): its options, its
  # sources and its readers, every fault by path. `Macaw.Data.Monitor` carries the
  # relations; this holds its checks so the loop reads alone.

  alias Macaw.Data.Source.Request

  # The request fields a reader asks; `now` and `subscription` are the monitor's.
  @asks [:params, :window, :box, :region, :latest, :order, :budget, :reduce, :as_of, :viewer]

  def options(opts) do
    for {key, ok?, type} <- [
          {:every, is_integer(opts[:every]) and opts[:every] >= 0, :non_neg_integer},
          {:backoff_max, is_integer(opts[:backoff_max]) and opts[:backoff_max] > 0, :pos_integer},
          {:stale_after,
           opts[:stale_after] == nil or
             (is_integer(opts[:stale_after]) and opts[:stale_after] > 0), :pos_integer},
          {:limit, is_integer(opts[:limit]), :integer}
        ],
        not ok?,
        do: {[key], {:type, type}}
  end

  def sources(sources) when is_map(sources) and not is_struct(sources) do
    for {name, s} <- Enum.sort(sources),
        source(s) == nil,
        do: {[:sources, name], {:type, :source}}
  end

  def sources(_sources), do: [{[:sources], {:type, :map}}]

  def source({%_{} = source, context}), do: {source, context}
  def source(%_{} = source), do: {source, nil}
  def source(_other), do: nil

  # The readers, each `%{source: name, ask: map}`, and every fault in them.
  def readers(readers, sources) when is_map(readers) and not is_struct(readers) do
    known = if is_map(sources) and not is_struct(sources), do: sources, else: %{}

    Enum.reduce(Enum.sort(readers), {%{}, []}, fn {name, given}, {ok, faults} ->
      case reader(given, known) do
        {:ok, reader} ->
          {Map.put(ok, name, reader), faults}

        {:error, found} ->
          {ok, faults ++ for({path, r} <- found, do: {[:readers, name | path], r})}
      end
    end)
  end

  def readers(_readers, _sources), do: {%{}, [{[:readers], {:type, :map}}]}

  def reader(given, sources) do
    with {:ok, fields} <- reader_fields(given),
         {:ok, source} <- reader_source(fields, sources),
         {:ok, ask} <- ask(Map.get(fields, :ask, [])) do
      {:ok, %{source: source, ask: ask}}
    end
  end

  defp reader_fields(given) do
    case Macaw.Data.Options.fields(given) do
      {:ok, fields} ->
        case Map.keys(fields) -- [:source, :ask] do
          [] -> {:ok, fields}
          unknown -> {:error, for(key <- Enum.sort(unknown), do: {[key], :unknown_key})}
        end

      {:error, _faults} ->
        {:error, [{[], {:type, :reader}}]}
    end
  end

  defp reader_source(%{source: source}, sources) do
    if Map.has_key?(sources, source),
      do: {:ok, source},
      else: {:error, [{[:source], {:unknown_source, source}}]}
  end

  defp reader_source(_fields, _sources), do: {:error, [{[:source], :required}]}

  # A reader's request fields, checked as a request checks them at a placeholder `now`.
  def ask(given) do
    with {:ok, fields} <- ask_fields(given),
         {:ok, _request} <- request_of(fields, ~U[1970-01-01 00:00:00Z]),
         do: {:ok, fields}
  end

  defp ask_fields(given) do
    case Macaw.Data.Options.fields(given) do
      {:ok, fields} ->
        case for(key <- Map.keys(fields), key not in @asks, do: {[:ask, key], :unknown_key}) do
          [] -> {:ok, fields}
          unknown -> {:error, Enum.sort(unknown)}
        end

      {:error, _faults} ->
        {:error, [{[:ask], {:type, :keyword}}]}
    end
  end

  defp request_of(fields, at) do
    case Request.new(Map.put(fields, :now, at)) do
      {:ok, request} -> {:ok, request}
      {:error, faults} -> {:error, for({path, r} <- faults, do: {[:ask | path], r})}
    end
  end
end
