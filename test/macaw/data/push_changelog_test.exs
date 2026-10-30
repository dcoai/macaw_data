defmodule Macaw.Data.PushChangelogTest do
  @moduledoc """
  The changelog (spec/01 §2.5, §4.1–§4.4): numbered increments and the snapshot's
  handoff by position.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Macaw.Data.{Delivery, Schema, Table}
  alias Macaw.Data.Schema.Cache
  alias Macaw.Data.Source.{Description, Push}

  @schema Schema.new!(%{"t" => %{type: :number, window: true}, "v" => %{type: :number}})
  @version Schema.version(@schema)

  defp push, do: Push.new(:ticks, make_ref(), cache: Cache.new([{:ticks, @schema}]))

  defp rows(ts), do: for(t <- ts, do: %{"t" => t, "v" => t})

  defp delivery(rows, served \\ []),
    do: Delivery.new(rows, schema: @version, served: served)

  defp snapshot(rows, position), do: delivery(rows, position: position)

  defp increment(push, seq, rows),
    do: send_in(push, Push.increment_message(push.ref, seq, delivery(rows)))

  defp snapshotted(push, rows, position),
    do: send_in(push, Push.snapshot_message(push.ref, snapshot(rows, position)))

  defp send_in(push, message) do
    {:ok, push} = Push.receive(push, message)
    push
  end

  defp drain(push), do: Push.drain(push, fn _ -> flunk("describe asked") end)

  # The held rows, sorted, as a multiset to compare.
  defp held(push) do
    case Push.held(push) do
      nil ->
        []

      delivery ->
        delivery
        |> Delivery.named_rows()
        |> Enum.map(&Map.new(&1, fn {k, v} -> {to_string(k), v} end))
        |> Enum.sort_by(&{&1["t"], &1["v"]})
    end
  end

  @tag verifies: "push-numbered"
  test "a repeated or older increment is dropped whole, increments apply by number, and identical rows are both held" do
    push =
      push()
      |> increment(1, rows([1]))
      |> increment(1, rows([1]))
      |> drain()

    assert held(push) == rows([1])
    assert push.ignored == %{repeat: 1}

    # Out of order within one drain: applied by number, no gap.
    push = push |> increment(3, rows([3])) |> increment(2, rows([2])) |> drain()
    assert held(push) == rows([1, 2, 3])
    assert push.errors == [] and Push.refetch(push) == nil

    # An older one, after a drain, is dropped whole too.
    push = push |> increment(2, rows([9])) |> drain()
    assert held(push) == rows([1, 2, 3])
    assert push.ignored == %{repeat: 2}

    # Two identical rows are two rows, in one increment or across two.
    push = push |> increment(4, rows([5, 5])) |> increment(5, rows([5])) |> drain()
    assert held(push) == rows([1, 2, 3, 5, 5, 5])
  end

  @tag verifies: "push-gap"
  test "a gap is recorded and answered with a refetch, and the snapshot that fills it applies what was held back" do
    push = push() |> increment(1, rows([1])) |> drain()
    push = push |> increment(4, rows([4])) |> increment(5, rows([5])) |> drain()

    assert held(push) == rows([1])
    assert push.errors == [{:gap, 2, 3}]
    assert Push.refetch(push) == {:gap, 2, 3}

    # The snapshot reflects increments up to 3: 4 and 5, held back, apply after it.
    push = push |> snapshotted(rows([1, 2, 3]), 3) |> drain()
    assert held(push) == rows([1, 2, 3, 4, 5])
    assert Push.refetch(push) == nil

    # A snapshot fetched by the holder hands off the same way.
    push = push |> increment(7, rows([7])) |> drain()
    assert Push.refetch(push) == {:gap, 6, 6}
    push = push |> Push.snapshot(snapshot(rows([1, 2, 3, 4, 5, 6]), 6)) |> drain()
    assert held(push) == rows([1, 2, 3, 4, 5, 6, 7])
    assert Push.refetch(push) == nil
  end

  @tag verifies: "push-handoff"
  property "a snapshot hands off by position: no increment is applied twice or lost" do
    check all(
            n <- integer(1..25),
            position <- integer(0..n),
            stale <- integer(0..n),
            cut <- integer(0..n),
            drains <- list_of(boolean(), length: n + 3)
          ) do
      # The source's changelog: increment i inserts row i. The snapshot reflects the
      # first `position` of them, and arrives after `cut` increments were sent; a stale
      # snapshot of `min(stale, position)` arrives after the real one.
      changes = for i <- 1..n, do: {:increment, i}
      sent = Enum.take(changes, cut) ++ [{:snapshot, position}] ++ Enum.drop(changes, cut)
      sent = sent ++ [{:snapshot, min(stale, position) - 1}]

      push =
        sent
        |> Enum.zip(drains)
        |> Enum.reduce(push(), fn {message, drain?}, push ->
          push =
            case message do
              {:increment, i} -> increment(push, i, rows([i]))
              {:snapshot, p} when p >= 0 -> snapshotted(push, rows(Enum.to_list(1..p//1)), p)
              {:snapshot, _none} -> push
            end

          if drain?, do: drain(push), else: push
        end)
        |> drain()

      # The held relation is the snapshot plus every later increment: each row once.
      assert held(push) == rows(Enum.to_list(1..n))
      assert push.errors == []
    end
  end

  test "a snapshot older than the position held is dropped whole, one with no position recorded" do
    push = push() |> increment(1, rows([1])) |> increment(2, rows([2])) |> drain()
    push = push |> snapshotted(rows([]), 0) |> drain()
    assert held(push) == rows([1, 2])
    assert push.ignored == %{stale_snapshot: 1}

    {:ok, push} = Push.receive(push, Push.snapshot_message(push.ref, delivery(rows([9]))))
    push = drain(push)
    assert held(push) == rows([1, 2])
    assert push.errors == [{:snapshot, :no_position}]
  end

  test "the held relation keeps the window field's order" do
    push = push() |> increment(1, rows([5, 1])) |> increment(2, rows([3])) |> drain()
    assert Table.column(Push.held(push) |> Delivery.table!(), "t") == [1, 3, 5]
  end

  # -- retractions, range replacements and resolution (spec/01 §4.2, §4.3) -----------------

  @tapped Schema.new!(%{
            "id" => %{type: :category, identity: true},
            "t" => %{type: :number, window: true},
            "v" => %{type: :number}
          })

  defp tapped(served \\ []),
    do: Push.new(:taps, make_ref(), cache: Cache.new([{:taps, @tapped}])) |> then(&{&1, served})

  defp change({push, served}, seq, opts) do
    {rows, opts} = Keyword.pop(opts, :rows, [])
    opts = Keyword.put_new(opts, :served, served)
    d = Delivery.new(rows, [schema: Schema.version(@tapped)] ++ opts)
    {send_in(push, Push.increment_message(push.ref, seq, d)) |> drain(), served}
  end

  defp start({push, served}, rows, served_snapshot \\ []) do
    d =
      Delivery.new(rows,
        schema: Schema.version(@tapped),
        served: Keyword.merge([position: 0], served_snapshot ++ served)
      )

    {push |> Push.snapshot(d) |> drain(), served}
  end

  defp tap(id, t, v), do: %{"id" => id, "t" => t, "v" => v}

  defp holding({push, _served}), do: held(push) |> Enum.sort_by(&{&1["id"], &1["t"], &1["v"]})
  defp faults({push, _served}), do: push.errors
  defp ignored({push, _served}), do: push.ignored

  @tag verifies: "push-retract"
  test "a retraction matches by identity, held window value and the fields it names, one copy per unit of weight" do
    base = [tap("a", 1, 10), tap("a", 1, 20), tap("b", 1, 1), tap("b", 1, 1), tap("c", 2, 5)]
    s = tapped() |> start(base)

    # Two rows of one identity and instant, differing in v: the named v picks exactly one.
    a = s |> change(1, retracted: [tap("a", 1, 20)])
    assert holding(a) == Enum.sort_by(base -- [tap("a", 1, 20)], &{&1["id"], &1["t"], &1["v"]})
    assert faults(a) == []

    # Two identical taps: one retraction leaves one; two retract both.
    b = s |> change(1, retracted: [%{"id" => "b", "t" => 1}])
    assert Enum.count(holding(b), &(&1["id"] == "b")) == 1
    b2 = s |> change(1, retracted: [tap("b", 1, 1), tap("b", 1, 1)])
    assert Enum.count(holding(b2), &(&1["id"] == "b")) == 0

    # Identity and window value alone, where one row is held there, retract it.
    c = s |> change(1, retracted: [%{"id" => "c", "t" => 2}])
    refute Enum.any?(holding(c), &(&1["id"] == "c"))

    # A row not held, one held only at another window value, and one that can't tell
    # the two "a" rows apart: each recorded, nothing changed.
    bad =
      s
      |> change(1,
        retracted: [tap("z", 1, 1), %{"id" => "c", "t" => 9}, %{"id" => "a", "t" => 1}]
      )

    assert holding(bad) == holding(s)

    assert faults(bad) == [
             {:retract, :not_held, tap("z", 1, 1)},
             {:retract, :moved, %{"id" => "c", "t" => 9}},
             {:retract, :ambiguous, %{"id" => "a", "t" => 1}}
           ]

    # With no identity declared, by the whole row.
    plain = push() |> increment(1, rows([1, 1, 2])) |> drain()
    gone = Delivery.new([], schema: @version, retracted: rows([1]))
    {:ok, plain} = Push.receive(plain, Push.increment_message(plain.ref, 2, gone))

    plain = drain(plain)
    assert held(plain) == rows([1, 2])

    # An update that moves a row is one increment: the retraction of its old place and
    # the insertion of its new one.
    moved = s |> change(1, retracted: [%{"id" => "c", "t" => 2}], rows: [tap("c", 7, 5)])
    assert tap("c", 7, 5) in holding(moved) and tap("c", 2, 5) not in holding(moved)
  end

  @tag verifies: "push-replace"
  test "a range replacement is exactly its rows over its range and identities, its conflicts recorded" do
    base = for id <- ["a", "b"], t <- 1..6, do: tap(id, t, 0)
    s = tapped() |> start(base)

    # [2, 5) of "a" is exactly the rows given; "b" and the rest of "a" untouched.
    r = s |> change(1, replace: [%{from: 2, to: 5, identities: ["a"], rows: [tap("a", 3, 9)]}])
    a = for %{"id" => "a"} = row <- holding(r), do: {row["t"], row["v"]}
    assert a == [{1, 0}, {3, 9}, {5, 0}, {6, 0}]
    assert Enum.count(holding(r), &(&1["id"] == "b")) == 6

    # It equals the row retractions and insertions it stands for.
    rows_form =
      s
      |> change(1,
        retracted: [tap("a", 2, 0), tap("a", 3, 0), tap("a", 4, 0)],
        rows: [tap("a", 3, 9)]
      )

    assert holding(rows_form) == holding(r)

    # to: nil covers everything from `from`, every identity.
    open = s |> change(1, replace: [%{from: 4, to: nil, identities: nil, rows: [tap("b", 9, 1)]}])

    assert Enum.map(holding(open), &{&1["id"], &1["t"]}) ==
             [{"a", 1}, {"a", 2}, {"a", 3}, {"b", 1}, {"b", 2}, {"b", 3}, {"b", 9}]

    # A conflicting insertion or retraction inside the range, a row outside it and an
    # overlapping replacement: recorded and not applied.
    c =
      s
      |> change(1,
        replace: [
          %{from: 2, to: 4, identities: ["a"], rows: [tap("a", 2, 7), tap("a", 4, 7)]},
          %{from: 3, to: 6, identities: nil, rows: []}
        ],
        retracted: [tap("a", 3, 0), tap("b", 1, 0)],
        rows: [tap("a", 2, 8), tap("b", 8, 0)]
      )

    assert faults(c) == [
             {:overlap, {3, 6}},
             {:conflict, tap("a", 3, 0)},
             {:outside, tap("a", 4, 7)},
             {:conflict, tap("a", 2, 8)}
           ]

    a = for %{"id" => "a"} = row <- holding(c), do: {row["t"], row["v"]}
    assert a == [{1, 0}, {2, 7}, {4, 0}, {5, 0}, {6, 0}]
    b = for %{"id" => "b"} = row <- holding(c), do: row["t"]
    assert b == [2, 3, 4, 5, 6, 8]

    # Retractions apply before replacements, insertions last: a retraction outside the
    # range and an insertion of the same row in one increment leave it held.
    order = s |> change(1, retracted: [tap("b", 6, 0)], rows: [tap("b", 6, 0)])
    assert holding(order) == holding(s)

    # A schema with no window field takes only the whole range.
    log = Schema.new!(%{"msg" => %{type: :text}})
    lp = Push.new(:log, make_ref(), cache: Cache.new([{:log, log}]))
    inc = fn rows, opts -> Delivery.new(rows, [schema: Schema.version(log)] ++ opts) end
    {:ok, lp} = Push.receive(lp, Push.increment_message(lp.ref, 1, inc.([%{"msg" => "x"}], [])))

    {:ok, lp} =
      Push.receive(lp, Push.increment_message(lp.ref, 2, inc.([], replace: [%{from: 1, to: 2}])))

    {:ok, lp} =
      Push.receive(
        lp,
        Push.increment_message(lp.ref, 3, inc.([], replace: [%{rows: [%{"msg" => "y"}]}]))
      )

    lp = drain(lp)
    assert held(lp) == [%{"msg" => "y"}]
    assert lp.errors == [{:replace, :no_window_field}]
  end

  @tag verifies: "push-thinned"
  test "against a thinned holding an unheld retraction is ignored, not an error" do
    for thinned <- [[capped: true], [reduced_by: :source], [reduced_by: :runtime]] do
      s = tapped() |> start([tap("a", 1, 1)], thinned)
      t = s |> change(1, retracted: [tap("a", 5, 1), tap("z", 1, 1), tap("a", 1, 1)])
      assert holding(t) == []
      assert faults(t) == []
      assert ignored(t) == %{unheld: 2}
    end

    complete = tapped() |> start([tap("a", 1, 1)]) |> change(1, retracted: [tap("z", 1, 1)])
    assert faults(complete) == [{:retract, :not_held, tap("z", 1, 1)}]
    assert ignored(complete) == %{}
  end

  @tag verifies: "push-resolution"
  test "an increment at another resolution is not merged and is answered with a refetch" do
    {push, _} = s = tapped() |> start([tap("a", 1, 1)], resolution: 60)

    {mismatch, _} = s |> change(1, rows: [tap("a", 2, 2)], served: [resolution: 1])
    assert held(mismatch) == held(push)
    assert mismatch.errors == [{:resolution, 60, 1}]
    assert Push.refetch(mismatch) == {:resolution, 60, 1}

    # The snapshot at the subscription's resolution hands off by position and clears it.
    snap =
      Delivery.new([tap("a", 1, 1), tap("a", 2, 2)],
        schema: Schema.version(@tapped),
        served: [position: 1, resolution: 1]
      )

    {after_, _} =
      {mismatch |> Push.snapshot(snap) |> drain(), []}
      |> change(2, rows: [tap("a", 3, 3)], served: [resolution: 1])

    assert Push.refetch(after_) == nil
    assert Enum.map(held(after_), & &1["t"]) == [1, 2, 3]
  end

  # -- the integral (spec/01 §2.5) ---------------------------------------------------------

  @tag verifies: "model-integral"
  property "the held relation is the integral of any changelog, however split, coalesced or repeated" do
    check all(
            steps <-
              list_of(
                tuple(
                  {member_of([:insert, :retract, :move, :replace, :mixed]),
                   list_of(integer(0..1000), length: 6)}
                ),
                min_length: 1,
                max_length: 20
              ),
            drains <- list_of(boolean(), length: 80),
            repeats <- list_of(integer(1..20), max_length: 4),
            switch <- integer(0..25)
          ) do
      {changes, models} = changelog(steps)
      n = length(changes)
      ref = make_ref()
      push = Push.new(:taps, ref, cache: Cache.new([{:taps, @tapped}]))
      send = fn push, d -> send_in(push, Push.increment_message(ref, d.seq, d.delivery)) end

      {push, _drains} =
        changes
        |> Enum.reduce({push, drains}, fn %{seq: seq} = change, {push, [drain? | drains]} ->
          # A refetch at another resolution lands just before this increment.
          push =
            if seq == switch,
              do: Push.snapshot(push, junk(seq - 1)) |> drain(),
              else: push

          push = send.(push, change)

          # A repeat of the one before is dropped whole.
          push =
            if seq in repeats and seq > 1, do: send.(push, Enum.at(changes, seq - 2)), else: push

          push =
            if seq == switch do
              push = drain(push)
              assert Push.refetch(push) == {:resolution, 60, nil}

              snapshot =
                Delivery.new(Enum.at(models, seq),
                  schema: Schema.version(@tapped),
                  served: [position: seq]
                )

              push |> Push.snapshot(snapshot) |> drain()
            else
              push
            end

          {if(drain?, do: drain(push), else: push), drains ++ [drain?]}
        end)

      push = drain(push)
      sorted = &Enum.sort_by(&1, fn r -> {r["id"], r["t"], r["v"]} end)
      assert holding({push, []}) == sorted.(Enum.at(models, n))
      expected = if switch in 1..n//1, do: [{:resolution, 60, nil}], else: []
      assert push.errors == expected
      assert Push.refetch(push) == nil
    end
  end

  @tag verifies: "model-integral"
  property "the held relation is the integral through Table.apply/2, settled ranges' deltas and their compaction included" do
    check all(
            steps <-
              list_of(
                tuple(
                  {member_of([:insert, :retract, :move, :replace, :mixed]),
                   list_of(integer(0..1000), length: 6)}
                ),
                min_length: 1,
                max_length: 20
              ),
            drains <- list_of(boolean(), length: 40),
            max_runs: 40
          ) do
      {changes, models} = changelog(steps)
      ref = make_ref()
      # Spans of 5 over t in 0..25, settled as the changelog goes: most changes reach a
      # settled chunk's delta, and enough of them compact it.
      push = Push.new(:taps, ref, cache: Cache.new([{:taps, @tapped}]), chunk_span: 5)

      {push, _drains} =
        Enum.reduce(changes, {push, drains}, fn %{seq: seq, delivery: d},
                                                {push, [drain? | drains]} ->
          d = %{d | served: %{d.served | complete_until: min(seq * 2, 25)}}
          push = send_in(push, Push.increment_message(ref, seq, d))
          {if(drain?, do: drain(push), else: push), drains ++ [drain?]}
        end)

      push = drain(push)
      sorted = &Enum.sort_by(&1, fn r -> {r["id"], r["t"], r["v"]} end)
      assert holding({push, []}) == sorted.(Enum.at(models, length(changes)))
      assert push.errors == []

      table = Push.held(push).rows
      ts = Table.column(table, "t")
      assert ts == Enum.sort_by(ts, &{&1 == nil, &1})
    end
  end

  @tag verifies: "push-held-table"
  test "held/1's rows are a chunked table of the source's origin, changed through Table.apply/2" do
    {push, _} =
      tapped()
      |> then(fn {_push, served} ->
        {Push.new(:taps, make_ref(), cache: Cache.new([{:taps, @tapped}]), chunk_span: 10),
         served}
      end)
      |> start(Enum.map(0..9, &tap("a", &1, &1)) ++ [tap("b", 12, 0)], complete_until: 10)
      |> change(1, retracted: [tap("a", 3, 3)], rows: [tap("b", 4, 1)])

    held = Push.held(push)
    assert %Table{} = table = held.rows

    assert Table.origin(table) == %{source: :taps, resolution: nil, window: "t", span: 10}
    assert Table.names(table) == ["id", "t", "v"]

    [{settled, _, _}, {open, _, _}] = Table.chunks(table)
    assert Table.Chunk.id(settled) == {:taps, nil, 0}
    assert Table.Chunk.delta?(settled)
    refute Table.Chunk.delta?(open)

    assert holding({push, []}) ==
             Enum.sort_by(
               (Enum.map(0..9, &tap("a", &1, &1)) -- [tap("a", 3, 3)]) ++
                 [tap("b", 4, 1), tap("b", 12, 0)],
               &{&1["id"], &1["t"], &1["v"]}
             )

    # Rows that don't pack are recorded and not applied.
    {push, _} = change({push, []}, 2, rows: [tap("a", 20, "not a number")])
    assert [{:table, [{["v", 0], {:type, :number}}]}] = push.errors
    assert Push.held(push).rows == table
  end

  # A snapshot at another resolution: what a holder fetched at another window.
  defp junk(position),
    do:
      Delivery.new([tap("q", 0, 0)],
        schema: Schema.version(@tapped),
        served: [position: position, resolution: 60]
      )

  # Each step's increment, and the relation after each step (the first empty), built
  # directly.
  defp changelog(steps) do
    {changes, models} =
      steps
      |> Enum.with_index(1)
      |> Enum.reduce({[], [[]]}, fn {step, seq}, {changes, [model | _] = models} ->
        {opts, model} = step(step, model)

        d =
          Delivery.new(
            Keyword.get(opts, :rows, []),
            [schema: Schema.version(@tapped)] ++ Keyword.delete(opts, :rows)
          )

        {[%{seq: seq, delivery: d} | changes], [model | models]}
      end)

    {Enum.reverse(changes), Enum.reverse(models)}
  end

  # Nothing held: an insertion, whatever the step was.
  defp step({kind, [c0, c1, c2 | _]}, []) when kind != :insert,
    do: step({:insert, [c0, c1, c2, 0, 1, 0]}, [])

  defp step({:insert, [c0, c1, c2, c3, c4, _]}, model) do
    fresh = for i <- 0..rem(c0, 3), do: tap(id(c1 + i), rem(c2 + i * 7, 25), rem(c3 + i, 3))
    # Sometimes a copy of a held row: a duplicate.
    dup =
      if model != [] and rem(c4, 2) == 0, do: [Enum.at(model, rem(c4, length(model)))], else: []

    rows = fresh ++ dup
    {[rows: rows], model ++ rows}
  end

  defp step({:retract, [c0, c1, c2 | _]}, model) do
    gone = picks(model, [c1] ++ if(rem(c0, 2) == 0, do: [c2], else: []))
    {[retracted: gone], model -- gone}
  end

  defp step({:move, [_c0, c1, c2 | _]}, model) do
    [row] = picks(model, [c1])
    moved = %{row | "t" => rem(c2, 25)}
    {[retracted: [row], rows: [moved]], (model -- [row]) ++ [moved]}
  end

  defp step({:replace, [c0, c1, c2, c3, c4, c5]}, model) do
    from = if rem(c0, 4) == 0, do: nil, else: rem(c1, 20)
    to = if rem(c2, 3) == 0, do: nil, else: (from || 0) + rem(c2, 8) + 1
    identities = Enum.at([nil, ["a"], ["b"]], rem(c3, 3))
    lo = from || 0
    hi = to || 25

    rows =
      for i <- 0..rem(c4, 3)//1, i > 0 do
        id = if identities, do: hd(identities), else: id(c5 + i)
        tap(id, lo + rem(c5 + i, hi - lo), rem(c5, 3))
      end

    scope = %{from: from, to: to, identities: identities, rows: rows}
    {[replace: [scope]], Enum.reject(model, &in_scope?(&1, scope)) ++ rows}
  end

  defp step({:mixed, [c0, c1, c2, c3, c4, c5]}, model) do
    {[retracted: gone], model} = step({:retract, [c0, c1, c2, 0, 0, 0]}, model)
    {[rows: rows], model} = step({:insert, [c3, c4, c5, c0, 1, 0]}, model)
    {[retracted: gone, rows: rows], model}
  end

  defp id(c), do: Enum.at(["a", "b"], rem(c, 2))

  # Distinct held copies, by index.
  defp picks(model, choices) do
    choices
    |> Enum.map(&rem(&1, length(model)))
    |> Enum.uniq()
    |> Enum.map(&Enum.at(model, &1))
  end

  defp in_scope?(row, %{from: from, to: to, identities: ids}) do
    t = row["t"]
    (ids == nil or row["id"] in ids) and (from == nil or t >= from) and (to == nil or t < to)
  end

  # -- settled ranges (spec/01 §4.4) --------------------------------------------------------

  @tag verifies: "push-settled"
  test "complete_until is carried forward and never moves backwards within a subscription" do
    s = tapped() |> start([tap("a", 1, 1)], complete_until: 5)
    assert Push.held(elem(s, 0)).served.complete_until == 5

    # Carried forward over an increment that states none, advanced by one that does.
    s = s |> change(1, rows: [tap("a", 6, 1)])
    assert Push.held(elem(s, 0)).served.complete_until == 5
    s = s |> change(2, rows: [tap("a", 7, 1)], served: [complete_until: 8])
    assert Push.held(elem(s, 0)).served.complete_until == 8

    # A smaller one is recorded, the held claim kept, and the changes still apply.
    s = s |> change(3, rows: [tap("a", 2, 1)], served: [complete_until: 6])
    assert Push.held(elem(s, 0)).served.complete_until == 8
    assert faults(s) == [{:complete_until, :backwards, 8, 6}]
    assert tap("a", 2, 1) in holding(s)

    # A snapshot is held to the same check.
    {push, _} = s

    back =
      Delivery.new([tap("a", 1, 1)],
        schema: Schema.version(@tapped),
        served: [position: 3, complete_until: 4]
      )

    push = push |> Push.snapshot(back) |> drain()
    assert Push.held(push).served.complete_until == 8
    assert List.last(push.errors) == {:complete_until, :backwards, 8, 4}

    # A new subscription starts afresh; with none there is no claim.
    fresh = tapped() |> start([tap("a", 1, 1)], complete_until: 2)
    assert Push.held(elem(fresh, 0)).served.complete_until == 2
    none = tapped() |> start([tap("a", 1, 1)]) |> change(1, rows: [tap("a", 2, 1)])
    assert Push.held(elem(none, 0)).served.complete_until == nil
  end

  @tag verifies: "push-lateness"
  test "a declared lateness refuses changes past its bound; without it any age is accepted" do
    base = [tap("a", 1, 1), tap("a", 50, 1)]

    # Without lateness, a change of any age is accepted, before complete_until too.
    any = tapped() |> start(base, complete_until: 100)
    any = any |> change(1, rows: [tap("a", 0, 9)], retracted: [tap("a", 1, 1)])
    assert faults(any) == [] and tap("a", 0, 9) in holding(any)

    # With lateness 10 and complete_until 100 the bound is 90.
    late = fn ->
      {Push.new(:taps, make_ref(), cache: Cache.new([{:taps, @tapped}]), lateness: 10), []}
    end

    s = late.() |> start(base, complete_until: 100)

    r =
      s
      |> change(1,
        rows: [tap("a", 89, 2), tap("a", 90, 2)],
        retracted: [tap("a", 50, 1)]
      )

    assert faults(r) == [{:late, tap("a", 50, 1), 90}, {:late, tap("a", 89, 2), 90}]
    assert holding(r) == [tap("a", 1, 1), tap("a", 50, 1), tap("a", 90, 2)]

    # A replacement reaching past the bound is refused whole, never clipped.
    whole = s |> change(1, replace: [%{from: 80, to: nil, rows: [tap("a", 95, 3)]}])
    assert faults(whole) == [{:late, {80, nil}, 90}]
    assert holding(whole) == base
    open = s |> change(1, replace: [%{rows: []}])
    assert faults(open) == [{:late, {nil, nil}, 90}]
    fine = s |> change(1, replace: [%{from: 90, rows: [tap("a", 95, 3)]}])
    assert faults(fine) == [] and tap("a", 95, 3) in holding(fine)

    # A snapshot is the relation itself: never refused.
    {push, _} = s

    snap =
      Delivery.new([tap("a", 1, 7)],
        schema: Schema.version(@tapped),
        served: [position: 0, complete_until: 100]
      )

    push = push |> Push.snapshot(snap) |> drain()
    assert held(push) == [tap("a", 1, 7)] and push.errors == []

    # Over a time window field the bound is a Duration back from the claim.
    timed = Schema.new!(%{"at" => %{type: :time}, "v" => %{type: :number}})
    t0 = ~U[2026-10-30 12:00:00Z]

    p =
      Push.new(:timed, make_ref(),
        cache: Cache.new([{:timed, timed}]),
        lateness: Duration.new!(hour: 1)
      )

    snap =
      Delivery.new([], schema: Schema.version(timed), served: [position: 0, complete_until: t0])

    rows = [
      %{"at" => ~U[2026-10-30 10:59:59Z], "v" => 1},
      %{"at" => ~U[2026-10-30 11:00:00Z], "v" => 2}
    ]

    inc = Delivery.new(rows, schema: Schema.version(timed))
    p = p |> Push.snapshot(snap) |> send_in(Push.increment_message(p.ref, 1, inc)) |> drain()
    assert p.errors == [{:late, hd(rows), ~U[2026-10-30 11:00:00Z]}]
    assert Delivery.named_rows(Push.held(p)) == tl(rows)

    # A lateness that can't be taken from the claim (a number from a time) is recorded,
    # and bounds nothing.
    q = Push.new(:timed, make_ref(), cache: Cache.new([{:timed, timed}]), lateness: 10)
    q = q |> Push.snapshot(snap) |> send_in(Push.increment_message(q.ref, 1, inc)) |> drain()
    assert q.errors == [{:lateness, :incompatible, t0}]
    assert Delivery.named_rows(Push.held(q)) == rows

    # A description's lateness: a Duration over a time window field, a number over a
    # number one, refused with no window field.
    numbered = Schema.new!(%{"t" => %{type: :number, window: true}})
    assert {:ok, %{lateness: 5}} = Description.new(schema: numbered, lateness: 5)
    assert {:ok, %{lateness: nil}} = Description.new(schema: numbered)

    assert {:ok, %{lateness: %Duration{}}} =
             Description.new(schema: timed, lateness: Duration.new!(day: 2))

    assert Description.new(schema: numbered, lateness: Duration.new!(day: 2)) ==
             {:error, [{[:lateness], {:type, :number}}]}

    assert Description.new(schema: numbered, lateness: -1) ==
             {:error, [{[:lateness], {:type, :number}}]}

    assert Description.new(schema: timed, lateness: 60) ==
             {:error, [{[:lateness], {:type, :duration}}]}

    windowless = Schema.new!(%{"msg" => %{type: :text}})

    assert Description.new(schema: windowless, lateness: 5) ==
             {:error, [{[:lateness], :no_window_field}]}
  end
end
