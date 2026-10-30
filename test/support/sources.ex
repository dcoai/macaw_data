defmodule Macaw.Data.Test.Sources do
  @moduledoc """
  Sources for the conformance kit's negatives (spec/01 §9): each is honest unless given a
  flaw, and each flaw breaks one rule of the contract and nothing else. Ported from
  visualize's `Visualize.Test.Feeds.Broken` and `Fleet`.
  """

  defmodule Broken do
    @moduledoc """
    A source whose rows are `%{t: 0..19, v: …}`, one series a tick apart, `t` its numeric
    window field. It honors a numeric window, a budget (every `k`-th row,
    `reduced_by: :source`, the resolution `k`), `as_of` and push, declares itself viewer
    independent, and `emit/1` pushes one new row under a new version of its schema, the
    schema first.
    """
    @behaviour Macaw.Data.Source

    alias Macaw.Data.{Delivery, Schema}
    alias Macaw.Data.Source.{Description, Push}

    @enforce_keys [:agent]
    defstruct [:agent, :flaw]

    @flaws [
      nil,
      :down,
      :unstable_version,
      :wrong_version,
      :hand_built,
      :stale_version,
      :served_window_lie,
      :missing_row,
      :capped_lie,
      :uncapped_lie,
      :reduction_unrecorded,
      :runtime_claim,
      :resolution_lie,
      :window_overrun,
      :budget_overrun,
      :push_undeclared,
      :no_handshake,
      :data_before_schema,
      :misnumbered,
      :keeps_pushing,
      :raises,
      :ticks_as_time,
      :no_window_field,
      :stamp_as_number,
      :misspelled_unit,
      :identified,
      :no_identity,
      :clock,
      :viewer_dependent,
      :as_of_ignored,
      :as_of_origin_lie
    ]

    @last 19

    @doc "The source with a flaw (`nil` for an honest one), its agent linked to the caller."
    def new(flaw \\ nil) when flaw in @flaws do
      {:ok, agent} =
        Agent.start_link(fn ->
          %{subscribers: %{}, seqs: %{}, generation: 0, describes: 0, fetches: 0}
        end)

      %__MODULE__{agent: agent, flaw: flaw}
    end

    @doc "Every flaw the source can be given."
    def flaws, do: tl(@flaws)

    @impl true
    def describe(%__MODULE__{flaw: :down}, _context), do: {:error, :down}

    def describe(%__MODULE__{agent: agent, flaw: flaw} = source, _context) do
      n = Agent.get_and_update(agent, &{&1.describes, %{&1 | describes: &1.describes + 1}})

      schema = if flaw == :unstable_version, do: schema("call #{n}", flaw), else: schema(source)

      schema =
        if flaw == :wrong_version,
          do: %{schema | version: String.duplicate("0", 64)},
          else: schema

      supports =
        if flaw == :push_undeclared,
          do: [:window, :budget, :as_of],
          else: [:window, :budget, :as_of, :push]

      description =
        Description.new!(
          schema: schema,
          supports: supports,
          params: %{"scale" => %{type: :number, default: 1}},
          viewer_independent: true
        )

      # A description built by hand around `Description.new/1`, its parameter's default
      # not of its type.
      if flaw == :hand_built,
        do: {:ok, %{description | params: %{"scale" => %{type: :number, default: "one"}}}},
        else: {:ok, description}
    end

    @impl true
    def fetch(%__MODULE__{flaw: :down}, _request), do: {:error, :down}

    def fetch(%__MODULE__{flaw: flaw} = source, request) do
      case bounds(request.window) do
        {:ok, from, to} ->
          {:ok, served(source, flaw, from, to, request)}

        # One raise is the flaw; more would only add crash reports to the test log.
        :error when flaw == :raises and request.window == [:not, :a_time] ->
          raise ArgumentError, "unreadable window #{inspect(request.window)}"

        :error ->
          {:error, {:window, request.window}}
      end
    end

    @impl true
    def subscribe(%__MODULE__{flaw: :down}, _pid), do: {:error, :down}

    def subscribe(%__MODULE__{agent: agent, flaw: flaw} = source, pid) do
      ref = make_ref()
      Agent.update(agent, &put_in(&1.subscribers[ref], pid))
      if flaw != :no_handshake, do: send(pid, Push.schema_message(ref, schema(source)))
      {:ok, ref}
    end

    @impl true
    def unsubscribe(%__MODULE__{flaw: :keeps_pushing}, _ref), do: :ok

    def unsubscribe(%__MODULE__{agent: agent}, ref) do
      Agent.update(agent, &%{&1 | subscribers: Map.delete(&1.subscribers, ref)})
    end

    @doc "One new row pushed to every subscriber, under a new version of the schema."
    def emit(%__MODULE__{agent: agent, flaw: flaw}) do
      # Each subscription's increments are numbered from 1, one past the last; the
      # misnumbered flaw skips one.
      step = if flaw == :misnumbered, do: 2, else: 1

      {generation, subscribers} =
        Agent.get_and_update(agent, fn state ->
          seqs =
            Map.new(state.subscribers, fn {ref, _pid} ->
              {ref, Map.get(state.seqs, ref, 0) + step}
            end)

          state = %{state | generation: state.generation + 1, seqs: seqs}
          numbered = for {ref, pid} <- state.subscribers, do: {ref, pid, seqs[ref]}
          {{state.generation, numbered}, state}
        end)

      schema = schema("generation #{generation}", flaw)
      t = 100 + generation

      delivery =
        Delivery.new([row(t, 1, flaw)],
          types: types(flaw),
          served: [window: [t, t]],
          schema: Schema.version(schema)
        )

      for {ref, pid, seq} <- subscribers do
        messages = [Push.schema_message(ref, schema), Push.increment_message(ref, seq, delivery)]

        messages = if flaw == :data_before_schema, do: Enum.reverse(messages), else: messages
        Enum.each(messages, &send(pid, &1))
      end

      :ok
    end

    defp schema(%__MODULE__{agent: agent, flaw: flaw}) do
      case Agent.get(agent, & &1.generation) do
        0 -> schema("Value", flaw)
        n -> schema("generation #{n}", flaw)
      end
    end

    # The tick is a `:number` window field; three flaws misdescribe it: ticks called
    # `:time`, a window source that names no window field, and a second `:time` field
    # written as numbers.
    defp schema(label, flaw) when is_binary(label) do
      t =
        case flaw do
          :ticks_as_time -> %{type: :time}
          :no_window_field -> %{type: :number}
          _honest -> %{type: :number, window: true}
        end

      fields = %{t: t, v: %{type: :number, label: label}}
      fields = if flaw == :stamp_as_number, do: Map.put(fields, :at, %{type: :time}), else: fields

      # Rows about two units, which `:identified` names in every row and `:no_identity`
      # leaves out of some.
      fields =
        if flaw in [:identified, :no_identity],
          do: Map.put(fields, :unit, %{type: :category, identity: true}),
          else: fields

      misspelled(Schema.new!(fields), flaw)
    end

    # A schema assembled around `Schema.new/1`, its value field in a unit the vocabulary
    # does not read: the struct a source could build by hand.
    defp misspelled(%Schema{fields: fields} = schema, :misspelled_unit),
      do: %{schema | fields: put_in(fields, ["v", :unit], "mss")}

    defp misspelled(schema, _flaw), do: schema

    defp types(:stamp_as_number), do: %{t: :number, v: :number, at: :number}

    defp types(flaw) when flaw in [:identified, :no_identity],
      do: %{t: :number, v: :number, unit: :text}

    defp types(:ticks_as_time), do: %{t: :number, v: :number}
    defp types(_flaw), do: %{t: :number, v: :number}

    defp row(t, v, :stamp_as_number), do: %{t: t, v: v, at: t}
    defp row(t, v, :identified), do: %{t: t, v: v, unit: if(rem(t, 2) == 0, do: "a", else: "b")}
    defp row(t, v, :no_identity) when rem(t, 3) == 0, do: %{t: t, v: v, unit: nil}
    defp row(t, v, :no_identity), do: row(t, v, :identified)
    defp row(t, v, _flaw), do: %{t: t, v: v}

    defp bounds(nil), do: {:ok, nil, nil}

    defp bounds([from, to] = window) do
      if Enum.all?(window, &(is_nil(&1) or is_number(&1))), do: {:ok, from, to}, else: :error
    end

    defp bounds(_window), do: :error

    # The honest answer, then the one rule a flaw breaks.
    defp served(source, flaw, from, to, request) do
      lo = max(from || 0, 0)
      hi = min(to || @last, @last)
      lo = if flaw == :uncapped_lie and from != nil, do: lo + 3, else: lo
      lo = if flaw == :window_overrun, do: 0, else: lo
      hi = if flaw == :window_overrun, do: @last, else: hi
      shift = shift(source, flaw, request)
      scale = request.params["scale"]

      rows = for t <- lo..hi//1, do: row(t, rem(t * 7, 5) * scale + shift, flaw)
      rows = if flaw == :missing_row and from != nil, do: List.delete_at(rows, 2), else: rows

      budget = request.budget

      {rows, step} =
        if budget && flaw != :budget_overrun && length(rows) > budget do
          step = ceil(length(rows) / budget)
          {Enum.take_every(rows, step), step}
        else
          {rows, 1}
        end

      reduced_by =
        cond do
          flaw == :runtime_claim -> :runtime
          step > 1 and flaw != :reduction_unrecorded -> :source
          true -> nil
        end

      origin =
        case {request.as_of, flaw} do
          {nil, _flaw} ->
            nil

          {_as_of, :as_of_origin_lie} ->
            %{source: :broken, request: "", as_of: ~U[1999-01-01 00:00:00Z]}

          {as_of, _flaw} ->
            %{source: :broken, request: "", as_of: as_of}
        end

      Delivery.new(rows,
        types: types(flaw),
        served: [
          window: [if(flaw == :served_window_lie, do: lo + 2, else: lo), hi],
          resolution: if(flaw == :resolution_lie, do: 2, else: step),
          capped: flaw == :capped_lie and from != nil,
          reduced_by: reduced_by
        ],
        origin: origin,
        schema:
          if(flaw == :stale_version,
            do: String.duplicate("0", 64),
            else: Schema.version(schema(source))
          )
      )
    end

    # What three flaws add to every value: a count of the fetches (an answer moving with a
    # clock of the source's own), the viewer, or `now` where `as_of` was asked.
    defp shift(%__MODULE__{agent: agent}, :clock, _request),
      do: Agent.get_and_update(agent, &{&1.fetches, %{&1 | fetches: &1.fetches + 1}})

    defp shift(_source, :viewer_dependent, request), do: :erlang.phash2(request.viewer, 1_000)

    defp shift(_source, :as_of_ignored, %{as_of: %DateTime{}, now: now}),
      do: rem(DateTime.to_unix(now), 7)

    defp shift(_source, _flaw, _request), do: 0
  end

  defmodule Fleet do
    @moduledoc """
    A fleet of cars as a source, for the region and `latest`: rows `%{t, car, x, y}` over
    ticks `0..11`, three cars a tick, `t` its numeric window field and `car` its declared
    identity. It names `[:window, :region, :latest]` and answers them by its own code
    rather than `Macaw.Data.Window`'s. A flaw breaks one rule: `:region_overrun` ignores
    the region, `:latest_twice` ignores `latest`, `:stale_latest` serves each car's first
    row.
    """
    @behaviour Macaw.Data.Source

    alias Macaw.Data.{Delivery, Schema}
    alias Macaw.Data.Source.Description

    defstruct flaw: nil

    @last 11
    @cars ["a", "b", "c"]

    @doc "The fleet's source with a flaw, `nil` for an honest one."
    def new(flaw \\ nil) when flaw in [nil, :region_overrun, :latest_twice, :stale_latest],
      do: %__MODULE__{flaw: flaw}

    @doc "The fleet's schema."
    def schema do
      Schema.new!(%{
        t: %{type: :number, window: true},
        car: %{type: :category, identity: true},
        x: %{type: :number},
        y: %{type: :number}
      })
    end

    @doc "Every row the fleet holds, in tick order, the cars in order within a tick."
    def rows do
      for t <- 0..@last,
          {car, i} <- Enum.with_index(@cars),
          do: %{t: t, car: car, x: rem(t * 3 + i * 5, 10), y: rem(t * 7 + i * 2, 10)}
    end

    @impl true
    def describe(%__MODULE__{}, _context),
      do: Description.new(schema: schema(), supports: [:window, :region, :latest])

    @impl true
    def fetch(%__MODULE__{flaw: flaw}, request) do
      [from, to] = request.window || [nil, nil]
      lo = max(from || 0, 0)
      hi = min(to || @last, @last)
      rows = Enum.filter(rows(), &(&1.t >= lo and &1.t <= hi))

      rows =
        if flaw == :region_overrun,
          do: rows,
          else: Enum.filter(rows, &in_region?(&1, request.region))

      rows = if request.latest and flaw != :latest_twice, do: last_of_each(rows, flaw), else: rows

      {:ok,
       Delivery.new(rows,
         types: %{t: :number, car: :text, x: :number, y: :number},
         served: [window: [lo, hi]],
         schema: Schema.version(schema())
       )}
    end

    defp in_region?(_row, nil), do: true

    defp in_region?(row, region) do
      Enum.all?(region, fn {field, [from, to]} ->
        value = Map.get(row, field)
        value != nil and (from == nil or value >= from) and (to == nil or value <= to)
      end)
    end

    defp last_of_each(rows, flaw) do
      pick =
        if flaw == :stale_latest,
          do: &Enum.min_by(&1, fn r -> r.t end),
          else: &Enum.max_by(&1, fn r -> r.t end)

      kept = rows |> Enum.group_by(& &1.car) |> Enum.map(fn {_car, rs} -> pick.(rs) end)
      Enum.filter(rows, &(&1 in kept))
    end
  end

  defmodule Places do
    @moduledoc """
    Four places as a source, for the box: rows `%{at, name}`, `at` a `:point` window
    field, the source naming `[:box]` and keeping the positions in it, across the
    antimeridian too. Its flaw `:box_overrun` ignores the box.
    """
    @behaviour Macaw.Data.Source

    alias Macaw.Data.{Delivery, Schema, Window}
    alias Macaw.Data.Source.Description

    defstruct flaw: nil

    @places [
      %{at: {2.35, 48.86}, name: "Paris"},
      %{at: {-74.0, 40.7}, name: "New York"},
      %{at: {179.0, -17.7}, name: "Suva"},
      %{at: {-179.9, -16.5}, name: "Taveuni"}
    ]

    @doc "The places' source with a flaw, `nil` for an honest one."
    def new(flaw \\ nil) when flaw in [nil, :box_overrun], do: %__MODULE__{flaw: flaw}

    @doc "The places' schema."
    def schema,
      do: Schema.new!(%{at: %{type: :point, window: true}, name: %{type: :text}})

    @impl true
    def describe(%__MODULE__{}, _context),
      do: Description.new(schema: schema(), supports: [:box])

    @impl true
    def fetch(%__MODULE__{flaw: flaw}, request) do
      rows =
        if request.box == nil or flaw == :box_overrun,
          do: @places,
          else: Enum.filter(@places, &Window.in_box?(&1.at, request.box))

      {:ok,
       Delivery.new(rows,
         types: %{at: :point, name: :text},
         served: [window: request.box],
         schema: Schema.version(schema())
       )}
    end
  end
end
