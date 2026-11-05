defmodule Macaw.Data.Source do
  @moduledoc """
  The source contract (spec/01 §2): anything a component's slot reads. One contract
  serves feeds, queries, derived sources, state sources and exports. It is a strict
  superset of visualize's `Visualize.Feed`: an existing feed is a source with no
  parameters.

  A source is a struct whose module implements this behavior:

  - `describe(source, context)`: what the source is, a `Macaw.Data.Source.Description`.
    It takes the host's configuration for the source as `context`, **never a viewer**, so
    it is answered at boot and cached by schema version;
  - `fetch(source, request)`: one answer, a `Macaw.Data.Delivery`, for a
    `Macaw.Data.Source.Request`;
  - `subscribe(source, pid)` and `unsubscribe(source, ref)`, optional, for a source that
    pushes (spec/01 §4).

  **Errors are values:** every callback answers `{:error, reason}` rather than raising.

  The functions here dispatch to a source's module. `fetch/3` checks the request's
  parameters against the description's before the call (`Macaw.Data.Parameter.validate/2`):
  a request with a bad parameter never reaches the source, and the source receives every
  parameter, defaults filled in.

  """

  alias Macaw.Data.{Delivery, Parameter, Schema, Window}
  alias Macaw.Data.Source.{Description, Request}

  @typedoc "A source: a struct whose module implements `Macaw.Data.Source`."
  @type t :: struct()

  @doc "What the source is, from the host's configuration for it; never a viewer."
  @callback describe(source :: t(), context :: term()) ::
              {:ok, Description.t()} | {:error, term()}

  @doc "One answer for a request."
  @callback fetch(source :: t(), Request.t()) :: {:ok, Delivery.t()} | {:error, term()}

  @doc "The source's pushes sent to `pid`, tagged with the answered reference (spec/01 §4)."
  @callback subscribe(source :: t(), pid()) :: {:ok, reference()} | {:error, term()}

  @doc "A subscription stopped."
  @callback unsubscribe(source :: t(), reference()) :: :ok

  @optional_callbacks subscribe: 2, unsubscribe: 2

  @doc """
  The source's description, `{:ok, description}` or `{:error, reason}`. An answer that is
  neither is `{:error, {:bad_describe, answer}}`: a source's fault the caller can show. A
  term that is no source, no struct or one whose module has no `describe/2`, is
  `{:error, :not_a_source}`, which holds nothing of the term: it may hold credentials.
  """
  @spec describe(t(), term()) :: {:ok, Description.t()} | {:error, term()}
  def describe(source, context) do
    case implementer(source, :describe, 2) do
      nil -> {:error, :not_a_source}
      module -> described(module.describe(source, context))
    end
  end

  defp described({:ok, %Description{}} = ok), do: ok
  defp described({:error, _reason} = error), do: error
  defp described(other), do: {:error, {:bad_describe, other}}

  # The module of a struct that implements the callback. A struct literal does not load its
  # module, so it is loaded before it is asked.
  defp implementer(%module{}, name, arity) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, name, arity), do: module
  end

  defp implementer(_source, _name, _arity), do: nil

  @doc """
  One answer for a request, checked first against the description:
  `{:error, {:params, faults}}` without calling the source when a parameter is unknown,
  missing or not legal (`Macaw.Data.Parameter.validate/2`), and `{:error, {:order,
  faults}}` when the request's `order` names a field the schema does not describe, or one
  of a type with no order (`Macaw.Data.Source.Order.faults/2`), and `{:error, {:window,
  faults}}` when the request's window or a region field's range is inverted, its `from`
  after its `to` (`Macaw.Data.Window.check/2`'s `{path, {:window, :inverted}}`,
  macaw_data#122). Otherwise the source is called with every parameter, defaults filled
  in. An answer that is neither `{:ok, delivery}` nor `{:error, reason}` is `{:error,
  {:bad_fetch, answer}}`.
  """
  @spec fetch(t(), Description.t(), Request.t()) :: {:ok, Delivery.t()} | {:error, term()}
  def fetch(source, %Description{} = description, %Request{} = request) do
    case implementer(source, :fetch, 2) do
      nil -> {:error, :not_a_source}
      module -> checked_fetch(module, source, description, request)
    end
  end

  defp checked_fetch(module, source, description, request) do
    with {:ok, filled} <- params(description, request),
         :ok <- order(description, request),
         :ok <- ranges(description, request) do
      case module.fetch(source, %{request | params: filled}) do
        {:ok, %Delivery{}} = ok -> ok
        {:error, _reason} = error -> error
        other -> {:error, {:bad_fetch, other}}
      end
    end
  end

  defp params(%Description{params: params}, request) do
    case Parameter.validate(params, request.params) do
      {:ok, filled} -> {:ok, filled}
      {:error, faults} -> {:error, {:params, faults}}
    end
  end

  # A range asked backward, the window's or a region field's (macaw_data#122), is the
  # caller's mistake and no source sees it; every other fault `Window.check/2` finds is a
  # request the source answers as its own (spec/01 §9's unreadable requests).
  defp ranges(%Description{schema: schema}, request) do
    case Window.check(request, schema) do
      :ok ->
        :ok

      {:error, faults} ->
        case for({_path, {:window, :inverted}} = fault <- faults, do: fault) do
          [] -> :ok
          inverted -> {:error, {:window, inverted}}
        end
    end
  end

  defp order(%Description{schema: schema}, request) do
    case Macaw.Data.Source.Order.faults(request.order, schema) do
      [] -> :ok
      faults -> {:error, {:order, faults}}
    end
  end

  @doc """
  The source's pushes sent to `pid` (spec/01 §4): `{:ok, ref}`, `{:error, :no_push}` for a
  source whose module does not implement `subscribe/2`, or `{:error, :not_a_source}` for a
  term that is no source.
  """
  @spec subscribe(t(), pid()) :: {:ok, reference()} | {:error, term()}
  def subscribe(source, pid) when is_pid(pid) do
    case {implementer(source, :subscribe, 2), implementer(source, :describe, 2)} do
      {nil, nil} -> {:error, :not_a_source}
      {nil, _module} -> {:error, :no_push}
      {module, _} -> module.subscribe(source, pid)
    end
  end

  @doc "A subscription stopped; `:ok` for a source that does not push, and for a term that is no source."
  @spec unsubscribe(t(), reference()) :: :ok
  def unsubscribe(source, ref) when is_reference(ref) do
    case implementer(source, :unsubscribe, 2) do
      nil -> :ok
      module -> module.unsubscribe(source, ref)
    end
  end

  @doc """
  A map of sources by name, with the host's context for each, as the describe function
  `Macaw.Data.Schema.Cache.resolve/4` takes: a name's present schema,
  `{:error, :no_source}` for a name not in the map, or `{:error, :not_a_source}` for an
  entry that is no `{source, context}` pair of a source.
  """
  @spec describer(%{term() => {t(), term()}}) :: (term() -> {:ok, Schema.t()} | {:error, term()})
  def describer(sources) when is_map(sources) do
    fn name ->
      with {:ok, {source, context}} <- found(Map.fetch(sources, name)),
           {:ok, %Description{schema: schema}} <- describe(source, context) do
        {:ok, schema}
      end
    end
  end

  defp found(:error), do: {:error, :no_source}
  defp found({:ok, {_source, _context}} = entry), do: entry
  defp found({:ok, _entry}), do: {:error, :not_a_source}
end
