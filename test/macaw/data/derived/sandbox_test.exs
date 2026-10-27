defmodule Macaw.Data.Derived.SandboxTest do
  # The checker, compiling once and the bounded runner (spec/02 §6). Ported from visualize's
  # `Visualize.VirtualSource.SandboxTest`.
  use ExUnit.Case, async: true

  alias Macaw.Data.Derived.Sandbox
  alias Macaw.Data.Derived.Sandbox.{Allowlist, Cache, Compiled}

  @moduletag :capture_log

  doctest Macaw.Data.Derived.Sandbox

  # The names these functions use, made atoms when this module loads: a stored function's
  # names must already exist (`existing_atoms_only`), as a document's schema makes them.
  @names ~w(xs row cpu mean hosts acc i y z mem a b n v host load t trend change)a
  setup_all do
    {:ok, names: @names}
  end

  defp ok?(source, opts \\ []), do: match?({:ok, _quoted}, Sandbox.check(source, opts))

  defp reasons(source, opts \\ []) do
    {:error, faults} = Sandbox.check(source, opts)
    Enum.map(faults, &elem(&1, 1))
  end

  defp call(source, args, opts \\ []) do
    {:ok, compiled} = Sandbox.compile(source)
    Sandbox.run(compiled, args, opts)
  end

  describe "check/2: what a function may say" do
    test "calculation and mapping over rows" do
      assert ok?("""
             fn %{hosts: rows} ->
               cpu = Enum.map(rows, & &1.cpu)
               [%{n: Enum.count(rows), mean: Enum.sum(cpu) / max(length_of(cpu), 1)}]
             end
             """) == false

      assert ok?("""
             fn %{hosts: rows} ->
               cpu = Enum.map(rows, & &1.cpu)
               [%{n: Enum.count(rows), mean: Enum.sum(cpu) / max(Enum.count(cpu), 1)}]
             end
             """)
    end

    test "control structures, patterns and guards" do
      assert ok?("""
             fn
               [a, b | _] when a.cpu > b.cpu and is_number(a.cpu) -> :ok
               [_ | _] = rows ->
                 case Enum.count(rows) do
                   n when rem(n, 2) == 0 -> cond do n > 4 -> :error; true -> :ok end
                   _ -> if Integer.is_even(3), do: :ok, else: :error
                 end
               [] -> unless false, do: nil
             end
             """)
    end

    test "with, for, ranges, binaries, access and pipes" do
      assert ok?("""
             fn row ->
               with {:ok, x} <- Map.fetch(row, :a), y = x * 2 do
                 for i <- 1..y//1, i > 1, into: [], do: {i, row[:b]}
               else
                 _ -> <<"no", 0::size(8)>> <> String.duplicate("-", 2)
               end
               |> Enum.take(3)
             end
             """)
    end

    @tag verifies: "derived-allowlist-calls"
    test "binaries take every segment type, in expressions and patterns" do
      for type <-
            ~w(binary bits bitstring bytes integer float utf8 utf16 utf32 signed unsigned big little native) do
        assert ok?("fn x -> <<x::#{type}>> end"), type
      end

      assert ok?("fn x -> <<x::integer-size(8)-unit(1)-big>> end")
      assert ok?("fn x -> <<x::size(2)*4>> end")
      assert ok?("fn <<a::binary-size(2), _::binary>> -> a end")
    end

    test "captures of allowed functions and anonymous functions" do
      assert ok?("fn rows -> Enum.map(rows, &Integer.to_string/1) |> Enum.reduce(&max/2) end")
      assert ok?("fn rows -> f = fn x -> x + 1 end; Enum.map(rows, &f.(&1)) end")
      assert ok?("fn rows -> :math.pi() * :math.sqrt(Enum.count(rows)) + :math.pi end")
    end

    test "a for with reduce: takes accumulator clauses" do
      assert ok?("fn xs -> for x <- xs, reduce: 0 do acc -> acc + x end end")
    end
  end

  describe "check/2: the faults" do
    @tag verifies: "derived-checker-shape"
    test "too long and syntax; a name never seen is a string" do
      assert [{:too_long, 10, 19}] = reasons("fn rows -> rows end", max_source: 10)

      # A name the node never saw is read as its string, never made an atom (visualize D-195).
      assert ok?("fn r -> :zz_never_seen_atom_42 end")

      assert [{:syntax, _message}] = reasons("fn rows -> ")
    end

    @tag verifies: "derived-checker-shape"
    test "the source is one fn of an arity arity: holds, one or two by default (visualize D-228)" do
      assert [{:not_a_function, [1, 2]}] = reasons("1 + 1")
      assert [{:not_a_function, 1}] = reasons("1 + 1", arity: 1)
      assert ok?("fn a -> a end")
      assert ok?("fn a, b -> {a, b} end")
      assert [{:fn_arity, [3]}] = reasons("fn a, b, c -> {a, b, c} end")
      assert [{:fn_arity, [1, 2]}] = reasons("fn a -> a; a, b -> {a, b} end")
      assert [{:fn_arity, [2]}] = reasons("fn a, b -> a end", arity: 1)
      assert [{:fn_arity, [1]}] = reasons("fn a -> a end", arity: 2)
      assert ok?("fn a, b -> {a, b} end", arity: 2)
    end

    test "the context has no variables: a read of it is not checked, and vars: is no option" do
      # spec/02 §2.3: a variable is an input, so nothing reads the context's variables.
      assert ok?(~S|fn _rows, c -> c["vars"]["x"] end|, fields: [:cpu])
      assert ok?("fn _rows, c -> c.vars.x end", fields: [:cpu])

      assert_raise ArgumentError, ~r/unknown keys \[:vars\]/, fn ->
        Sandbox.check("fn x -> x end", vars: ["x"])
      end
    end

    @tag verifies: "derived-checker-reads"
    test "a read of the context is not a field's (visualize D-228)" do
      fields = [fields: [:cpu]]

      assert ok?(
               ~S|fn rows, c -> {c.inputs.hosts, c.inputs, c["inputs"]["hosts"], rows.cpu} end|,
               fields
             )

      assert [{:unknown_field, "mem"}] = reasons("fn rows, _c -> rows.mem end", fields)
      assert [{:unknown_field, "inputs"}] = reasons("fn rows -> rows.inputs end", fields)
    end

    @tag verifies: "derived-checker-refusals"
    test "every fault, by line" do
      assert {:error, faults} =
               Sandbox.check("""
               fn rows ->
                 x = File.read("a")
                 send(self(), x)
                 y
               end
               """)

      assert faults == [
               {2, {:restricted, {"File", "read", 1}}},
               {3, {:restricted, {:send, 2}}},
               {4, {:undefined_variable, "y"}}
             ]
    end

    @tag verifies: "derived-checker-reads"
    test "a map read on a variable is allowed; a call on one is dynamic" do
      assert ok?("fn row -> row.cpu end")
      assert [{:dynamic_call, "cpu"}] = reasons("fn row -> row.cpu() end")
      assert [{:dynamic_call, "cpu"}] = reasons("fn row -> row.cpu(1) end")
    end

    @tag verifies: "derived-checker-reads"
    test "fields: a map read names a schema's field, by either spelling" do
      assert ok?("fn row -> row.cpu end", fields: [:cpu])
      assert ok?("fn row -> row.cpu end", fields: ["cpu"])
      assert [{:unknown_field, "mem"}] = reasons("fn row -> row.mem end", fields: [:cpu])
    end

    @tag verifies: "derived-checker-reads"
    test "into: and Enum.into take a literal empty target" do
      for target <- ["%{}", "[]", ~s("")] do
        assert ok?("fn xs -> for x <- xs, into: #{target}, do: x end")
        assert ok?("fn xs -> Enum.into(xs, #{target}) end")
      end

      assert [{:into, :literal}] = reasons("fn xs -> for x <- xs, into: xs, do: x end")
      assert [{:into, :literal}] = reasons("fn xs -> Enum.into(xs, [1]) end")
      assert [{:into, :literal}] = reasons("fn xs -> xs |> Enum.into(%{a: 1}) end")
      assert ok?("fn xs -> Enum.into(xs, [], & &1) end")
      assert [{:into, :literal}] = reasons("fn xs -> Enum.map(xs, &Enum.into/2) end")
      assert [{:uniq, :literal}] = reasons("fn xs -> for x <- xs, uniq: xs, do: x end")
    end

    @tag verifies: ["derived-checker-compiles", "derived-allowlist-calls"]
    test "guards hold the guard-safe part" do
      assert [{:guard, {Enum, :count, 1}}] = reasons("fn xs when Enum.count(xs) > 1 -> xs end")
      assert [{:guard, {:<>, 2}}] = reasons(~S|fn x when x <> "a" == "ba" -> x end|)
    end

    @tag verifies: "derived-checker-refusals"
    test "a segment type the list does not hold is refused as written, its size an expression" do
      assert [{:restricted, {"frob", 0}}] = reasons("fn x -> <<x::frob>> end")
      assert [{:undefined_variable, "y"}] = reasons("fn x -> <<x::size(y)>> end")
    end

    @tag verifies: "derived-checker-compiles"
    test "patterns hold patterns" do
      assert {:pattern, :+} in reasons("fn x + 1 -> x end")
      assert [{:undefined_variable, "y"}] = reasons("fn ^y -> 1 end")
      assert [{:pattern, :^}] = reasons("fn x -> ^x end")
    end

    @tag verifies: "derived-checker-compiles"
    test "the clauses of an inner fn take one arity" do
      assert [{:fn_arity, [1, 2]}] = reasons("fn x -> fn a -> a; a, b -> b end end")
    end

    @tag verifies: "derived-checker-compiles"
    test "variables are scoped" do
      assert [{:undefined_variable, "a"}] = reasons("fn x -> case x do a -> a end; a end")
      assert [{:undefined_variable, "i"}] = reasons("fn x -> for i <- x, do: i; i end")
      assert ok?("fn x -> y = x; z = y + 1; z end")
    end
  end

  describe "compile/2" do
    @tag verifies: "derived-compile-once"
    test "a closure, its hash and its warnings" do
      assert {:ok, %Compiled{fun: fun, arity: 1, hash: hash, warnings: warnings}} =
               Sandbox.compile("fn x -> 1 end")

      assert is_function(fun, 1)
      assert hash == Sandbox.hash("fn x -> 1 end")
      assert [{1, message}] = warnings
      assert message =~ "unused"

      # Kept, not printed.
      assert ExUnit.CaptureIO.capture_io(:stderr, fn -> Sandbox.compile("fn y -> 2 end") end) ==
               ""
    end

    @tag verifies: "derived-compile-once"
    test "the checker's faults are the compile's" do
      assert {:error, [{1, {:restricted, {:send, 2}}}]} =
               Sandbox.compile("fn x -> send(x, 1) end")

      # A source the checker passes and the compiler refuses is one compile fault.
      assert {:error, [{nil, {:compile, message}}]} =
               Sandbox.compile("fn x -> <<x::utf8-size(8)>> end")

      assert is_binary(message)
    end

    @tag verifies: "derived-compile-once"
    test "a map read never calls a function, whatever its receiver holds" do
      assert {:error, :raised, BadMapError} = call("fn m -> m.halt end", [:erlang])
      assert {:ok, 3} = call("fn m -> m.halt end", [%{halt: 3}])
      assert {:ok, 2} = call("fn m -> m.cpu end", [%{"cpu" => 2}])
      # A guard reads a string-keyed row, as a function's inputs are (visualize D-195).
      assert {:ok, :ok} = call("fn m when m.cpu > 1 -> :ok; _ -> nil end", [%{"cpu" => 2}])
    end

    test "Integer's guards compile" do
      assert {:ok, :ok} = call("fn x when Integer.is_even(x) -> :ok; _ -> nil end", [2])
    end
  end

  describe "string interpolation and Macaw.Data.Reduce (visualize#769)" do
    test "interpolation checks: it is a binary over Kernel.to_string/1" do
      assert ok?(~S|fn row -> "#{row.host}: #{row.load}" end|)
      assert ok?(~S|fn row -> "load " <> "#{row.load * 2}%" end|)
      assert ok?("fn row -> to_string(row.load) end")
      assert ok?("fn row -> Kernel.to_string(row.load) end")
      assert ok?("fn rows -> Enum.map(rows, &to_string/1) end")
    end

    test "interpolation is not guard-safe, and its holes are walked" do
      assert [{:guard, {:to_string, 1}}] =
               reasons(~S|fn x when to_string(x) == "1" -> x end|)

      assert [{:restricted, {"File", "read", 1}}] = reasons(~S|fn x -> "#{File.read(x)}" end|)
      assert [{:undefined_variable, "y"}] = reasons(~S|fn x -> "#{y}" end|)
    end

    @tag verifies: "derived-allowlist-calls"
    test "every allowed function of every allowed module checks, called and captured" do
      for module <- Allowlist.modules(), {name, arity} <- Allowlist.allowed(module) do
        receiver = if module == :math, do: ":math", else: inspect(module)
        # Enum.into takes a literal empty target (§6.1), so its second argument is one.
        args =
          for i <- 1..arity//1,
              do: if({module, name, i} == {Enum, :into, 2}, do: "[]", else: "rows")

        call = "#{receiver}.#{name}(#{Enum.join(args, ", ")})"
        assert ok?("fn rows -> #{call} end"), call

        assert ok?("fn rows -> &#{receiver}.#{name}/#{arity} end") or
                 {module, name} == {Enum, :into},
               call
      end
    end

    @tag verifies: "derived-allowlist-calls"
    test "a function Macaw.Data.Reduce does not export, and the step-6 aggregates, are refused" do
      for name <- ["mode", "mean"] do
        assert [{:restricted, {Macaw.Data.Reduce, ^name, 1}}] =
                 reasons("fn rows -> Macaw.Data.Reduce.#{name}(rows) end")
      end
    end

    test "a stored function with interpolation and lttb runs through the bounded runner" do
      source = ~S"""
      fn rows ->
        kept = Macaw.Data.Reduce.lttb(rows, 3, &{&1.t, &1.load})
        total = Enum.sum_by(rows, & &1.load)
        "#{Enum.count(rows)} samples, total #{total}, kept #{Enum.map_join(kept, ",", & &1.t)}"
      end
      """

      rows = for t <- 0..4, do: %{t: t * 10, load: rem(t * 7, 5)}

      assert {:ok, "5 samples, total 10, kept 0," <> _} = call(source, [rows])
      assert {:ok, "0 samples, total 0, kept "} = call(source, [[]])
    end
  end

  describe "run/3" do
    @tag verifies: "derived-runner-outcomes"
    test "a value" do
      assert {:ok, [2, 4]} =
               call("fn rows -> Enum.map(rows, & &1.v * 2) end", [[%{v: 1}, %{v: 2}]])
    end

    @tag verifies: "derived-runner-outcomes"
    test "a raise is the exception's module, read from the exit" do
      assert {:error, :raised, ArithmeticError} = call("fn x -> 1 / x end", [0])
      assert {:error, :raised, FunctionClauseError} = call("fn 1 -> 1 end", [2])
      assert {:error, :raised, KeyError} = call("fn x -> Map.fetch!(x, :a) end", [%{}])
    end

    @tag verifies: "derived-runner-outcomes"
    test "the heap limit" do
      assert {:error, :memory, 100_000} =
               call("fn _ -> Enum.to_list(1..100_000_000_000) end", [nil], max_heap: 100_000)
    end

    @tag verifies: "derived-runner-reductions"
    test "the reductions cap kills a runaway" do
      assert {:error, :reductions, 1_000_000} =
               call(
                 "fn _ -> Enum.reduce(1..100_000_000_000_000, 0, fn x, acc -> rem(acc + x, 7) end) end",
                 [nil],
                 max_reductions: 1_000_000
               )
    end

    @tag verifies: "derived-runner-reductions"
    test "a call that answers over the cap is over it, its value dropped" do
      {:ok, compiled} =
        Sandbox.compile("fn n -> Enum.reduce(1..n, 0, fn x, acc -> acc + x end) end")

      assert {:ok, 5_000_050_000} = Sandbox.run(compiled, [100_000])

      assert {:error, :reductions, 1_000} =
               Sandbox.run(compiled, [100_000], max_reductions: 1_000)
    end

    @tag verifies: "derived-runner-outcomes"
    test "a host's function blocked in receive is hung at the liveness bound" do
      me = self()

      assert {:error, :hung, 20} =
               Sandbox.run(
                 fn ->
                   send(me, {:running, self()})
                   receive(do: (:never_sent -> :ok))
                 end,
                 [],
                 timeout: 20
               )

      # The call's process was killed and waited for: nothing it started outlives it.
      assert_received {:running, pid}
      refute Process.alive?(pid)
    end

    test "a function of two arguments: compiled with its arity, called with its context (visualize D-228)" do
      {:ok, compiled} =
        Sandbox.compile(~S|fn rows, c -> {Enum.count(rows), c["inputs"]["hosts"]["capped"]} end|)

      assert compiled.arity == 2

      assert {:ok, {2, true}} =
               Sandbox.run(compiled, [[1, 2], %{"inputs" => %{"hosts" => %{"capped" => true}}}])

      # The reductions bound holds for it as for one of one (visualize#856).
      {:ok, runaway} =
        Sandbox.compile(
          "fn _rows, c -> Enum.reduce(1..100_000_000_000_000, 0, fn x, acc -> rem(acc + x, c) end) end"
        )

      assert {:error, :reductions, 1_000_000} =
               Sandbox.run(runaway, [[], 7], max_reductions: 1_000_000)
    end

    @tag verifies: "derived-runner-outcomes"
    test "a host's function runs bounded too" do
      assert {:ok, 3} = Sandbox.run(&(&1 + &2), [1, 2])
      assert {:error, :raised, :exit} = Sandbox.run(fn -> exit(:boom) end, [])
    end

    @tag verifies: "derived-runner-tighten"
    test "each bound may be lowered, never raised (spec/02 §6.4)" do
      assert {:error, :reductions, 1_000} =
               Sandbox.run(fn -> Enum.reduce(1..1_000_000, 0, &+/2) end, [],
                 max_reductions: 1_000
               )

      for {key, over} <- [max_reductions: 100_000_001, timeout: 30_001, max_heap: 10_000_001] do
        assert_raise ArgumentError, ~r/never raised/, fn ->
          Sandbox.run(fn -> 1 end, [], [{key, over}])
        end
      end

      assert_raise ArgumentError, ~r/never raised/, fn ->
        Sandbox.check("fn x -> x end", max_source: 10_001)
      end

      assert {:error, [{nil, {:too_long, 5, _}}]} = Sandbox.check("fn x -> x end", max_source: 5)
    end
  end

  describe "the cache" do
    @tag verifies: "derived-compile-once"
    test "a source compiles once, a refusal included" do
      cache = Cache.new()
      {:ok, a, cache} = Cache.compile(cache, "fn x -> x end")
      {:ok, b, cache} = Cache.compile(cache, "fn x -> x end")
      assert a.fun == b.fun
      assert map_size(cache.entries) == 1

      {:error, faults, cache} = Cache.compile(cache, "fn x -> send(x, 1) end")
      {:error, ^faults, cache} = Cache.compile(cache, "fn x -> send(x, 1) end")
      assert map_size(cache.entries) == 2
    end

    @tag verifies: "derived-compile-once"
    test "keyed by the arity and the fields too" do
      {:ok, _c, cache} = Cache.compile(Cache.new(), "fn x -> x.cpu end", fields: [:cpu])

      {:error, [{1, {:unknown_field, "cpu"}}], cache} =
        Cache.compile(cache, "fn x -> x.cpu end", fields: [:mem])

      assert map_size(cache.entries) == 2

      # The arities a source was checked against are its key's (visualize D-228).
      {:ok, %Compiled{arity: 1}, cache} = Cache.compile(cache, "fn x -> x end")
      {:error, [{1, {:fn_arity, [1]}}], cache} = Cache.compile(cache, "fn x -> x end", arity: 2)
      {:ok, %Compiled{arity: 1}, cache} = Cache.compile(cache, "fn x -> x end", arity: [1])
      assert map_size(cache.entries) == 5
    end
  end

  @tag verifies: "derived-checker-refusals"
  test "format_error/1 words every reason" do
    for fault <- [
          {nil, {:too_long, 10, 20}},
          {1, {:unknown_atom, "zz"}},
          {1, {:syntax, "x"}},
          {nil, {:not_a_function, 1}},
          {nil, {:not_a_function, [1, 2]}},
          {1, {:fn_arity, [3]}},
          {1, {:restricted, {Enum, :random, 1}}},
          {1, {:restricted, {:send, 2}}},
          {1, {:restricted, :struct}},
          {1, {:restricted_atom, :__struct__}},
          {1, {:dynamic_call, "x"}},
          {1, {:unknown_field, "x"}},
          {1, {:into, :literal}},
          {1, {:uniq, :literal}},
          {1, {:undefined_variable, "x"}},
          {1, {:guard, {Enum, :count, 1}}},
          {1, {:guard, {:<>, 2}}},
          {1, {:pattern, :+}},
          {1, {:fn_arity, [1, 2]}},
          {nil, {:compile, "no"}},
          {nil, {:compile, {:reductions, 1}}},
          {nil, {:compile, {:hung, 1}}}
        ] do
      assert is_binary(Sandbox.format_error(fault))
    end
  end
end
