defmodule Macaw.Data.Source.Conformance do
  @moduledoc """
  The source conformance kit: the contract of spec/01 §2–§4 as checks every source runs
  (spec/01 §9).

  `check/3` runs one of eight checks against a source and answers its **findings**,
  `{check, reason}` terms, `[]` for a source that passes; `check/2` runs them all and
  `format/1` words a finding. `use Macaw.Data.Source.Conformance, opts` inside a module
  that uses `ExUnit.Case` writes one test per check that fails with the findings:

      defmodule MyApp.SourceTest do
        use ExUnit.Case, async: true

        use Macaw.Data.Source.Conformance,
          source: MyApp.Source.new(),
          requests: [[], [window: [10, 20]]],
          push: &MyApp.Source.emit/1
      end

  The kit drives the source through `Macaw.Data.Source` alone and calls every callback in
  a process of its own (`Macaw.Data.Bounded`), so a callback that raises is a finding
  (`{:raised, call, reason}`), not a crash of the check. It references no ExUnit function
  itself: `describe`, `test` and `flunk` appear only in the code `use` writes into the
  caller's module, so the kit loads in production. A callback is judged by the reductions
  its process spends, never by the clock, so a loaded host changes no verdict.

  Ported from visualize's `Visualize.Feed.Conformance`, with the checks a source's
  superset of a feed needs: a describe context, parameters, `as_of`, one answer per `now`
  and viewer independence.

  ## Options

    * `source:` the source (to `use`: an expression, evaluated in each test).
    * `context:` the host's configuration for the source, passed to `describe/2` (`nil`).
    * `requests:` what is asked, each a keyword list of `Macaw.Data.Source.Request` fields
      among `params`, `window`, `box`, `region`, `latest` and `as_of`; `[[]]` by default.
      A source naming a capability needs a request that probes it.
    * `budgets:` the budgets each request is fetched with, `[nil, 5]`.
    * `now:` the request's `now`, a `DateTime`; the moment the check starts by default.
    * `viewers:` two opaque viewers, the first asking every request and the second held
      to the same answer when the source declares itself viewer independent.
    * `as_of:` the instant an `:as_of` source is asked as of; a day before `now` by default.
    * `push:` a function of the source that makes it push; a source naming `:push` needs
      one.
    * `down:` a source of the same kind that cannot answer, held to error values.
    * `timeout:` the liveness bound: milliseconds before a callback that has not answered
      is hung (blocked, not slow), and the wait for a first push (`30_000`).
    * `reductions:` the most reductions one callback may spend, the source author's cost
      budget; `nil`, the default, makes no cost claim.
    * `processes:` pids or registered names whose reductions during a callback count
      toward its budget, for a source that does its work in a server (`[]`).
    * `quiet:` milliseconds of silence that end a push (`100`).
    * `name:` to `use` only: the `describe` block's name, `"source conformance"`.

  ## Examples

      iex> Macaw.Data.Source.Conformance.check(%Macaw.Data.Test.Reference{},
      ...>   requests: [[], [window: [2, 6]]])
      []

  """

  alias Macaw.Data.{Delivery, Schema, Source, Table, Window}
  alias Macaw.Data.Source.{Description, Request}
  alias Macaw.Data.Source.Conformance.{Call, Deliveries, Pushes, Regions, Words}

  @checks [
    :describe,
    :deliveries,
    :supports,
    :push,
    :errors,
    :unsubscribe,
    :determinism,
    :viewers
  ]

  @defaults [
    context: nil,
    requests: [[]],
    budgets: [nil, 5],
    now: nil,
    viewers: [%{conformance: :first}, %{conformance: :second}],
    as_of: nil,
    push: nil,
    down: nil,
    timeout: 30_000,
    reductions: nil,
    processes: [],
    quiet: 100
  ]

  @asks [:params, :window, :box, :region, :latest, :order, :as_of]

  @titles %{
    describe: "a valid description and a stable schema version",
    deliveries: "deliveries are well formed and honest",
    supports: "the declared capabilities are true",
    push: "the schema arrives before the data",
    errors: "errors are values, not crashes",
    unsubscribe: "unsubscribing stops pushes",
    determinism: "one request, one now, one answer",
    viewers: "a viewer-independent source answers every viewer alike"
  }

  @typedoc "One of the eight checks."
  @type check ::
          :describe
          | :deliveries
          | :supports
          | :push
          | :errors
          | :unsubscribe
          | :determinism
          | :viewers

  @typedoc "A fault one check found: `{check, reason}` (spec/01 §9)."
  @type finding :: {check(), term()}

  @doc """
  One ExUnit test per check, in a `describe` block, written into a module that uses
  `ExUnit.Case` (spec/01 §9). `source:` and `down:` are expressions evaluated in each
  test, in the test process.
  """
  defmacro __using__(opts) do
    # Only the options given are passed on, as the caller wrote them: `check/3` fills the
    # rest, so no default is spliced into the caller's code.
    opts =
      Keyword.validate!(opts, [:source, {:name, "source conformance"} | Keyword.keys(@defaults)])

    source =
      Keyword.get(opts, :source) || raise(ArgumentError, "the conformance kit needs source:")

    name = Keyword.fetch!(opts, :name)
    is_binary(name) || raise ArgumentError, "the conformance kit's name: is a string literal"

    {down, opts} = opts |> Keyword.drop([:source, :name]) |> Keyword.pop(:down)

    tests =
      for check <- @checks do
        # Only the errors check reads `down:`, so only its test evaluates the expression.
        opts = if check == :errors, do: [{:down, down} | opts], else: opts

        quote do
          test unquote("#{check}: #{@titles[check]}") do
            case Macaw.Data.Source.Conformance.check(
                   unquote(check),
                   unquote(source),
                   unquote(opts)
                 ) do
              [] ->
                :ok

              findings ->
                flunk(Enum.map_join(findings, "\n", &Macaw.Data.Source.Conformance.format/1))
            end
          end
        end
      end

    quote do
      describe unquote(name) do
        unquote({:__block__, [], tests})
      end
    end
  end

  @doc "The eight checks, in the order `check/2` runs them."
  @spec checks() :: [check(), ...]
  def checks, do: @checks

  @doc "Every check's findings for a source, concatenated in the order of `checks/0`."
  @spec check(Source.t(), keyword()) :: [finding()]
  def check(source, opts) when is_list(opts) do
    opts = Keyword.put_new_lazy(opts, :now, &DateTime.utc_now/0)
    Enum.flat_map(@checks, &check(&1, source, opts))
  end

  @doc """
  One check's findings for a source, `[]` when it passes (spec/01 §9). Raises
  `ArgumentError` for an unknown check, an unknown option or a request with a key that
  is not one of `params`, `window`, `box`, `region`, `latest` and `as_of`.
  """
  @spec check(check(), Source.t(), keyword()) :: [finding()]
  def check(check, source, opts) when check in @checks and is_list(opts) do
    o = opts |> Keyword.validate!(@defaults) |> Map.new() |> settled()
    for reason <- run(check, source, o), do: {check, reason}
  end

  def check(check, _source, _opts),
    do:
      raise(
        ArgumentError,
        "not a conformance check: #{inspect(check)}, one of #{inspect(@checks)}"
      )

  defp settled(o) do
    for ask <- o.requests do
      (Keyword.keyword?(ask) && Keyword.keys(ask) -- @asks == []) ||
        raise ArgumentError,
              "a conformance request is a keyword list of #{inspect(@asks)}, got #{inspect(ask)}"
    end

    [_first, _second] = o.viewers
    now = o.now || DateTime.utc_now()
    %{o | now: now, as_of: o.as_of || DateTime.add(now, -86_400)}
  end

  # -- describe ------------------------------------------------------------------------------

  defp run(:describe, source, o) do
    with {:ok, description} <- described(source, o) do
      description_faults(description) ++
        Deliveries.schema_faults(description.schema) ++
        window_field(description) ++
        case described(source, o) do
          {:ok, ^description} ->
            []

          {:ok, other} ->
            [{:unstable, Schema.version(description.schema), Schema.version(other.schema)}]

          faults ->
            faults
        end
    end
  end

  # -- deliveries ----------------------------------------------------------------------------

  defp run(:deliveries, source, o) do
    with {:ok, description} <- described(source, o) do
      for ask <- o.requests, budget <- o.budgets do
        Deliveries.probe(source, {ask, budget}, description, o)
      end
      |> List.flatten()
    end
  end

  # -- supports ------------------------------------------------------------------------------

  defp run(:supports, source, o) do
    with {:ok, %Description{supports: supports} = description} <- described(source, o) do
      if supports -- Description.capabilities() == [] and Enum.uniq(supports) == supports do
        fetch = &Deliveries.fetched(source, description, &1, o)

        window_honored(fetch, description, o) ++
          Regions.box(fetch, description, o) ++
          Regions.region(fetch, description, o) ++
          Regions.latest(fetch, description, o) ++
          Regions.order(fetch, description, o) ++
          budget_honored(fetch, supports, o) ++
          as_of_honored(source, description, o) ++
          push_honored(source, supports, o)
      else
        [{:supports, supports}]
      end
    end
  end

  # -- push ----------------------------------------------------------------------------------

  defp run(:push, source, o) do
    with {:ok, %Description{supports: supports}} <- described(source, o),
         true <- :push in supports || [],
         true <- o.push != nil || [{:no_probe, :push}],
         {:ok, ref} <- Pushes.subscribed(source, o) do
      handshake =
        receive do
          {:macaw_source, ^ref, message} -> message
        after
          0 -> :nothing
        end

      pushed = Pushes.stimulate(source, o)

      messages =
        Pushes.collect(ref, System.monotonic_time(:millisecond) + o.timeout, o.quiet, false, [])

      Pushes.unsubscribed(source, ref, o)
      Pushes.flush(ref)

      Pushes.sequence(handshake, messages, o) ++ pushed
    end
  end

  # -- errors --------------------------------------------------------------------------------

  defp run(:errors, source, o) do
    description =
      case described(source, o) do
        {:ok, description} -> description
        _faults -> nil
      end

    unreadable =
      if description do
        for request <- unreadable(o) do
          call = {:fetch, {:unreadable, request}}

          case call(fn -> Source.fetch(source, description, request) end, call, o) do
            {:ok, {:ok, %Delivery{}}} -> []
            {:ok, {:error, _reason}} -> []
            {:ok, other} -> [{:not_a_value, call, other}]
            {:error, fault} -> [fault]
          end
        end
      else
        []
      end

    List.flatten(unreadable) ++
      params_refused(source, description, o) ++
      unknown_ref(source, o) ++ down(o.down, description, o)
  end

  # -- unsubscribe ---------------------------------------------------------------------------

  defp run(:unsubscribe, source, o) do
    with {:ok, %Description{supports: supports}} <- described(source, o) do
      if :push in supports, do: Pushes.silenced(source, o), else: unknown_ref(source, o)
    end
  end

  # -- determinism ---------------------------------------------------------------------------

  defp run(:determinism, source, o) do
    with {:ok, description} <- described(source, o) do
      for ask <- o.requests, budget <- o.budgets do
        same(source, description, {ask, budget}, hd(o.viewers), hd(o.viewers), o, :answer_moved)
      end
      |> List.flatten()
    end
  end

  # -- viewers -------------------------------------------------------------------------------

  defp run(:viewers, source, o) do
    with {:ok, description} <- described(source, o) do
      [first, second] = o.viewers

      if description.viewer_independent do
        for ask <- o.requests, budget <- o.budgets do
          same(source, description, {ask, budget}, first, second, o, :viewer_dependent)
        end
        |> List.flatten()
      else
        []
      end
    end
  end

  # -- describing ----------------------------------------------------------------------------

  # The source's description, or the findings that stop a check that needs one.
  defp described(source, o) do
    case call(fn -> Source.describe(source, o.context) end, :describe, o) do
      {:ok, {:ok, %Description{schema: %Schema{}} = description}} -> {:ok, description}
      {:ok, {:error, {:bad_describe, other}}} -> [{:not_described, other}]
      {:ok, {:ok, other}} -> [{:not_described, other}]
      {:ok, {:error, reason}} -> [{:describe_error, reason}]
      {:error, fault} -> [fault]
    end
  end

  # A description `Description.new/1` accepts as it stands: a struct built by hand is held
  # to the same rules.
  defp description_faults(%Description{} = d) do
    case Description.new(Map.from_struct(d)) do
      {:ok, ^d} -> []
      {:ok, _other} -> [{:description_invalid, []}]
      {:error, faults} -> [{:description_invalid, faults}]
    end
  end

  # A source that honors windows names the field they are over; one that honors boxes, a
  # `:point` window field (spec/01 §1.3, §2.4).
  defp window_field(%Description{schema: schema, supports: supports}) do
    field = Schema.window_field(schema)
    type = field && type_of(schema, field)

    no_field =
      if :window in supports and type not in [:time, :number],
        do: [{:no_window_field, :window, type}],
        else: []

    no_point =
      if :box in supports and type != :point, do: [{:no_window_field, :box, type}], else: []

    no_field ++ no_point
  end

  defp type_of(schema, field) do
    {:ok, type} = Schema.fetch(schema, field, :type)
    type
  end

  # -- the supports check --------------------------------------------------------------------

  defp window_honored(fetch, %Description{supports: supports, schema: schema}, o) do
    time = Schema.window_field(schema)
    bounded = for ask <- o.requests, bounded?(Keyword.get(ask, :window)), do: ask

    cond do
      :window not in supports ->
        []

      bounded == [] ->
        [{:no_probe, :window}]

      true ->
        for ask <- bounded, budget <- o.budgets do
          window_kept(fetch, {ask, budget}, time)
        end
        |> List.flatten()
    end
  end

  defp bounded?([from, to]), do: from != nil or to != nil
  defp bounded?(_none), do: false

  defp window_kept(fetch, {ask, _budget} = probe, time) do
    window = Keyword.fetch!(ask, :window)

    case fetch.(probe) do
      {:ok, delivery, rows} ->
        served =
          if served_within?(delivery.served.window, window),
            do: [],
            else: [{:window_served, probe, delivery.served.window}]

        rows =
          case time && Enum.find(rows, &Deliveries.outside?(Table.get(&1, time), window)) do
            nil -> []
            row -> [{:window_row, probe, Table.get(row, time)}]
          end

        served ++ rows

      # A probe the source cannot answer is the deliveries check's to report.
      _faults ->
        []
    end
  end

  # A served window within the asked one: each bound the request gives is met or narrowed.
  defp served_within?([sf, st], [af, at]),
    do:
      (af == nil or
         (sf != nil and not Deliveries.before?(sf, af) and Deliveries.comparable?(sf, af))) and
        (at == nil or
           (st != nil and not Deliveries.before?(at, st) and Deliveries.comparable?(st, at)))

  defp served_within?(_served, _asked), do: false

  defp budget_honored(fetch, supports, o) do
    budgets = Enum.reject(o.budgets, &is_nil/1)

    cond do
      :budget not in supports ->
        []

      budgets == [] ->
        [{:no_probe, :budget}]

      true ->
        for ask <- o.requests, budget <- budgets do
          case fetch.({ask, budget}) do
            {:ok, _delivery, rows} when length(rows) > budget ->
              [{:over_budget, {ask, budget}, length(rows)}]

            _within_or_unanswered ->
              []
          end
        end
        |> List.flatten()
    end
  end

  # A source naming `:as_of` answers as of the instant asked: an origin it gives names
  # that instant, and a later `now` changes nothing of the answer.
  defp as_of_honored(source, %Description{supports: supports} = description, o) do
    if :as_of in supports do
      for ask <- o.requests do
        probe = {Keyword.put(ask, :as_of, o.as_of), nil}
        later = %{o | now: DateTime.add(o.now, 3600)}

        with {:ok, delivery, rows} <- Deliveries.fetched(source, description, probe, o),
             {:ok, _again, again} <- Deliveries.fetched(source, description, probe, later) do
          origin =
            case delivery.origin do
              %{as_of: as_of} when as_of != o.as_of -> [{:as_of_origin, probe, as_of}]
              _none_or_named -> []
            end

          moved = if sorted(rows) == sorted(again), do: [], else: [{:as_of_moved, probe}]
          origin ++ moved
        else
          _faults -> []
        end
      end
      |> List.flatten()
    else
      []
    end
  end

  defp push_honored(source, supports, o) do
    if :push in supports do
      probe = if o.push, do: [], else: [{:no_probe, :push}]

      case Pushes.subscribed(source, o) do
        {:ok, ref} ->
          Pushes.unsubscribed(source, ref, o)
          Pushes.flush(ref)
          probe

        [{:subscribe_error, reason}] ->
          [{:push_refused, reason} | probe]

        faults ->
          faults ++ probe
      end
    else
      me = self()
      %module{} = source

      # Asked of the module itself: `Source.subscribe/2` answers `:no_push` for a module
      # without the callback, and one that has it is what this clause looks for.
      if Code.ensure_loaded?(module) and function_exported?(module, :subscribe, 2) do
        case call(fn -> module.subscribe(source, me) end, :subscribe, o) do
          {:ok, {:error, _reason}} ->
            []

          {:ok, {:ok, ref} = answer} when is_reference(ref) ->
            Pushes.unsubscribed(source, ref, o)
            Pushes.flush(ref)
            [{:push_undeclared, answer}]

          {:ok, answer} ->
            [{:push_undeclared, answer}]

          {:error, fault} ->
            [fault]
        end
      else
        []
      end
    end
  end

  # -- determinism and viewers ---------------------------------------------------------------

  # One probe fetched as two viewers (or one viewer twice) at one `now`: the same rows, as
  # a set, and the same served terms. A row stamped after `now` arrived between the two
  # and is not compared.
  defp same(source, %Description{schema: schema} = description, probe, a, b, o, finding) do
    with {:ok, first, rows} <- Deliveries.fetched(source, description, probe, o, a),
         {:ok, second, again} <- Deliveries.fetched(source, description, probe, o, b) do
      time = Schema.window_field(schema)
      settled = &settled_rows(&1, time, o.now)

      if settled.(rows) == settled.(again) and first.served == second.served,
        do: [],
        else: [{finding, probe}]
    else
      # A probe the source cannot answer is the deliveries check's to report.
      _faults -> []
    end
  end

  defp settled_rows(rows, nil, _now), do: sorted(rows)

  defp settled_rows(rows, time, now) do
    rows
    |> Enum.reject(fn row ->
      value = Table.get(row, time)
      Window.instant?(value) and Window.compare(to_datetime(value), now) == :gt
    end)
    |> sorted()
  end

  defp to_datetime(%DateTime{} = t), do: t
  defp to_datetime(%NaiveDateTime{} = t), do: DateTime.from_naive!(t, "Etc/UTC")
  defp to_datetime(%Date{} = d), do: DateTime.new!(d, ~T[00:00:00], "Etc/UTC")

  defp sorted(rows), do: Enum.sort(rows)

  # -- errors --------------------------------------------------------------------------------

  # Requests no source can read as its own, built around `Request.new/1`: the source
  # answers each with a value, a delivery or an error, never a crash.
  defp unreadable(o) do
    for fields <- [
          [window: [:not, :a_time]],
          [window: [~U[2000-01-01 00:00:00Z], ~U[2000-01-02 00:00:00Z]]],
          [window: [0, 1]],
          [window: [0, ~U[2000-01-01 00:00:00Z]]],
          [box: %{west: 0, south: 0, east: 1, north: 1}],
          [region: %{"no such field" => [0, 1]}, latest: true]
        ],
        do: struct!(Request, [now: o.now, viewer: hd(o.viewers)] ++ fields)
  end

  # A parameter the source does not declare never reaches it: the answer is the
  # `{:params, faults}` value (spec/01 §2.2).
  defp params_refused(_source, nil, _o), do: []

  defp params_refused(source, description, o) do
    request = %Request{params: %{"no such parameter" => 1}, now: o.now, viewer: hd(o.viewers)}
    call = {:fetch, {:unreadable, request}}

    case call(fn -> Source.fetch(source, description, request) end, call, o) do
      {:ok, {:error, {:params, _faults}}} -> []
      {:ok, other} -> [{:params_accepted, other}]
      {:error, fault} -> [fault]
    end
  end

  defp unknown_ref(source, o) do
    case call(fn -> Source.unsubscribe(source, make_ref()) end, :unsubscribe, o) do
      {:ok, :ok} -> []
      {:ok, other} -> [{:unsubscribe, other}]
      {:error, fault} -> [fault]
    end
  end

  defp down(nil, _description, _o), do: []

  defp down(source, description, o) do
    me = self()
    %module{} = source
    request = %Request{now: o.now, viewer: hd(o.viewers)}
    call = {:fetch, {[], nil}}

    describe =
      case call(fn -> Source.describe(source, o.context) end, :describe, o) do
        {:ok, {:error, {:bad_describe, other}}} -> [{:not_a_value, :describe, other}]
        {:ok, {:error, _reason}} -> []
        {:ok, answer} -> [{:answered_down, :describe, answer}]
        {:error, fault} -> [fault]
      end

    # A down source cannot describe itself, so it is asked under the description of the
    # source it is the down kind of, which fills its parameters' defaults; with none, its
    # own callback is asked.
    fetch_down =
      if description,
        do: fn -> Source.fetch(source, description, request) end,
        else: fn -> module.fetch(source, request) end

    fetch =
      case call(fetch_down, call, o) do
        {:ok, {:error, _reason}} -> []
        {:ok, {:ok, _delivery} = answer} -> [{:answered_down, call, answer}]
        {:ok, other} -> [{:not_a_value, call, other}]
        {:error, fault} -> [fault]
      end

    subscribe =
      case call(fn -> Source.subscribe(source, me) end, :subscribe, o) do
        {:ok, {:error, _reason}} ->
          []

        {:ok, {:ok, ref} = answer} ->
          Pushes.flush(ref)
          [{:answered_down, :subscribe, answer}]

        {:ok, other} ->
          [{:not_a_value, :subscribe, other}]

        {:error, fault} ->
          [fault]
      end

    describe ++ fetch ++ subscribe ++ unknown_ref(source, o)
  end

  # -- isolation -----------------------------------------------------------------------------

  defp call(fun, call, o), do: Call.run(fun, call, o)

  # -- words ---------------------------------------------------------------------------------

  @doc """
  One finding as a line a person reads.

      iex> Macaw.Data.Source.Conformance.format({:supports, {:over_budget, {[], 5}, 9}})
      "supports: asked for at most 5 rows (fetch [] with budget 5), the source names :budget and served 9"
  """
  @spec format(finding()) :: String.t()
  def format({check, reason}), do: "#{check}: #{Words.words(reason)}"
end
