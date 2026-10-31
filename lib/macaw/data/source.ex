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

  alias Macaw.Data.{Delivery, Parameter, Schema}
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
  neither is `{:error, {:bad_describe, answer}}`: a source's fault the caller can show.
  """
  @spec describe(t(), term()) :: {:ok, Description.t()} | {:error, term()}
  def describe(%module{} = source, context) do
    case module.describe(source, context) do
      {:ok, %Description{}} = ok -> ok
      {:error, _reason} = error -> error
      other -> {:error, {:bad_describe, other}}
    end
  end

  @doc """
  One answer for a request, checked first against the description:
  `{:error, {:params, faults}}` without calling the source when a parameter is unknown,
  missing or not legal (`Macaw.Data.Parameter.validate/2`), and `{:error, {:order,
  faults}}` when the request's `order` names a field the schema does not describe, or one
  of a type with no order (`Macaw.Data.Source.Order.faults/2`). Otherwise the source is
  called with every parameter, defaults filled in. An answer that is neither `{:ok,
  delivery}` nor `{:error, reason}` is `{:error, {:bad_fetch, answer}}`.
  """
  @spec fetch(t(), Description.t(), Request.t()) :: {:ok, Delivery.t()} | {:error, term()}
  def fetch(%module{} = source, %Description{} = description, %Request{} = request) do
    with {:ok, filled} <- params(description, request),
         :ok <- order(description, request) do
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

  defp order(%Description{schema: schema}, request) do
    case Macaw.Data.Source.Order.faults(request.order, schema) do
      [] -> :ok
      faults -> {:error, {:order, faults}}
    end
  end

  @doc """
  The source's pushes sent to `pid` (spec/01 §4): `{:ok, ref}`, or `{:error, :no_push}` for
  a source whose module does not implement `subscribe/2`.
  """
  @spec subscribe(t(), pid()) :: {:ok, reference()} | {:error, term()}
  def subscribe(%module{} = source, pid) when is_pid(pid) do
    if push?(module), do: module.subscribe(source, pid), else: {:error, :no_push}
  end

  @doc "A subscription stopped; `:ok` for a source that does not push."
  @spec unsubscribe(t(), reference()) :: :ok
  def unsubscribe(%module{} = source, ref) when is_reference(ref) do
    if push?(module), do: module.unsubscribe(source, ref), else: :ok
  end

  # A struct literal does not load its module, so it is loaded before it is asked.
  defp push?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :subscribe, 2)

  @doc """
  A map of sources by name, with the host's context for each, as the describe function
  `Macaw.Data.Schema.Cache.resolve/4` takes: a name's present schema, or
  `{:error, :no_source}` for a name not in the map.
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
  defp found(ok), do: ok
end
