# raises.exs — no `raise`, `throw` or `exit` in lib/ outside the project's reasoned
# allowlist, ci/raises_allowlist.exs (dco-tek/macaw/macaw#243, #247). The Macaw family's
# reference copy is claude-tools' macaw_ci/raises.exs, vendored into each project's ci/
# byte for byte.
#
#   elixir ci/raises.exs         # checks ./lib against ./ci/raises_allowlist.exs
#   elixir ci/raises.exs DIR     # checks DIR/lib against DIR/ci/raises_allowlist.exs
#
# A Macaw library answers a failure as a value. A raise is allowed only where an entry
# names its function and says why, in one of four classes the check verifies:
#
#   %{at: {Macaw.Registry, :new!, 2}, class: :bang, reason: "..."}
#
#   :bang      a `!` twin: the function ends in `!` and the module defines its value twin,
#              the same name without `!`, at the same arity
#   :mix_task  how a Mix task fails: the module is a `Mix.Tasks.*`
#   :compile   refusing bad code while the caller compiles: a macro (`__using__`,
#              `__before_compile__` among them), or the module body, `at: {Module, nil, nil}`
#   :invariant a case no input can reach, kept with the reason it can't
#
# The calls found are `raise`, `reraise`, `throw`, `exit`, `Kernel.` and `:erlang.` forms of
# these, and `Mix.raise`, each attributed to the function it is written in. An implicit
# raise (`Map.fetch!/2`, `hd/1`, a failed match) can't be seen by reading the source: that
# is the audit's and the property tests' job. A raise outside the list, an entry whose
# class doesn't hold, a malformed entry and an entry that matches no raise each fail, as
# does a file that doesn't parse. The list defaults empty: prefer answering a value.

defmodule Raises do
  @allowlist "ci/raises_allowlist.exs"
  @classes [:bang, :mix_task, :compile, :invariant]
  @defs [:def, :defp, :defmacro, :defmacrop]
  @local [:raise, :reraise, :throw, :exit]
  @erlang [:error, :exit, :throw, :raise]

  @doc """
  Every raise site in a source: `%{module:, function:, arity:, kind:, line:, call:}`,
  `function` and `arity` nil in a module body; and every function the source defines,
  `%{module:, function:, arity:, kind:}`. A source that doesn't parse is `{:error, words}`.
  """
  def scan(source, file) do
    case Code.string_to_quoted(source, file: file, columns: false) do
      {:ok, ast} ->
        {:ok, walk(ast, %{module: nil, def: nil, quoted: false}, %{sites: [], defs: []})}

      {:error, {meta, message, token}} ->
        {:error, "#{file}:#{meta[:line]}: does not parse: #{message}#{token}"}
    end
  end

  defp walk({:defmodule, _, [name, [do: body]]}, ctx, acc),
    do: walk(body, %{ctx | module: module(name, ctx.module), def: nil}, acc)

  # Code inside a `quote` is generated into the caller: a function it defines is not this
  # module's, and a raise in it is attributed to the macro that writes it, marked quoted.
  defp walk({:quote, _, args}, ctx, acc) when is_list(args),
    do: walk(args, %{ctx | quoted: true}, acc)

  defp walk({kind, _, [head | rest]}, %{module: module, quoted: false} = ctx, acc)
       when kind in @defs and module != nil do
    {name, arity} = head(head)
    acc = %{acc | defs: [%{module: module, function: name, arity: arity, kind: kind} | acc.defs]}
    walk(rest, %{ctx | def: {kind, name, arity}}, acc)
  end

  defp walk({call, meta, args}, ctx, acc) when is_list(args) do
    acc =
      case raise_call(call, args) do
        nil -> acc
        words -> %{acc | sites: [site(ctx, meta, words) | acc.sites]}
      end

    walk(args, ctx, if(is_atom(call), do: acc, else: walk(call, ctx, acc)))
  end

  defp walk({left, right}, ctx, acc), do: walk(right, ctx, walk(left, ctx, acc))
  defp walk(list, ctx, acc) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, ctx, &2))
  defp walk(_leaf, _ctx, acc), do: acc

  # `raise/1,2`, `reraise/2,3`, `throw/1`, `exit/1`; their `Kernel.` and `:erlang.` forms;
  # `Mix.raise/1,2`. A variable named `raise` has no argument list and is no call.
  defp raise_call(name, args) when name in @local and args != [], do: Atom.to_string(name)

  defp raise_call({:., _, [{:__aliases__, _, [:Kernel]}, name]}, _args) when name in @local,
    do: "Kernel.#{name}"

  defp raise_call({:., _, [:erlang, name]}, _args) when name in @erlang, do: ":erlang.#{name}"
  defp raise_call({:., _, [{:__aliases__, _, [:Mix]}, :raise]}, _args), do: "Mix.raise"
  defp raise_call(_call, _args), do: nil

  defp site(ctx, meta, words) do
    {kind, name, arity} = ctx.def || {nil, nil, nil}

    %{
      module: ctx.module,
      function: name,
      arity: arity,
      kind: kind,
      line: meta[:line],
      call: words,
      quoted: ctx.quoted
    }
  end

  defp head({:when, _, [head | _guards]}), do: head(head)
  defp head({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp head({name, _, _context}) when is_atom(name), do: {name, 0}

  # A name written with `unquote` (`def unquote(name)(...)`) is named by its source.
  defp head({name, meta, args}), do: head({String.to_atom(Macro.to_string(name)), meta, args})

  # A nested `defmodule Inner` is `Outer.Inner`; `__MODULE__.Inner` is the same.
  defp module({:__aliases__, _, [{:__MODULE__, _, _} | rest]}, outer),
    do: Module.concat([outer | rest])

  defp module({:__aliases__, _, parts}, nil), do: Module.concat(parts)
  defp module({:__aliases__, _, parts}, outer), do: Module.concat([outer | parts])
  defp module(name, _outer) when is_atom(name), do: name

  @doc "Every problem in a tree's scans against the allowlist, one line each."
  def problems(scans, entries) do
    {sites, defs} =
      Enum.reduce(scans, {[], []}, fn {file, {:ok, scan}}, {sites, defs} ->
        {sites ++ Enum.map(scan.sites, &Map.put(&1, :file, file)), defs ++ scan.defs}
      end)

    malformed = malformed(entries)
    entries = entries -- Enum.map(malformed, &elem(&1, 0))
    listed = MapSet.new(entries, & &1.at)

    Enum.map(malformed, &elem(&1, 1)) ++
      for(
        site <- Enum.sort_by(sites, &{&1.file, &1.line}),
        not MapSet.member?(listed, at(site)),
        do:
          "#{site.file}:#{site.line}: #{name(at(site))} calls #{site.call}: not in #{@allowlist}"
      ) ++
      Enum.flat_map(entries, &judge(&1, sites, defs))
  end

  defp at(site), do: {site.module, site.function, site.arity}

  defp name({module, nil, nil}), do: "#{inspect(module)} (module body)"
  defp name({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"

  defp malformed(entries) do
    duplicates =
      entries |> Enum.frequencies_by(&Map.get(&1, :at)) |> Enum.filter(&(elem(&1, 1) > 1))

    for(
      entry <- entries,
      not match?(
        %{at: {m, f, a}, class: c, reason: r}
        when is_atom(m) and m != nil and
               ((is_atom(f) and f != nil and is_integer(a) and a >= 0) or (f == nil and a == nil)) and
               c in @classes and is_binary(r) and r != "",
        entry
      ),
      do:
        {entry,
         "#{@allowlist}: an entry needs at: {module, function, arity}, a class in #{inspect(@classes)} and a reason; got #{inspect(entry)}"}
    ) ++
      for {at, _n} <- duplicates,
          at != nil,
          do: {%{at: at}, "#{@allowlist}: #{inspect(at)} is listed more than once"}
  end

  # An entry matches a raise site, and its class holds of the function it names.
  defp judge(%{at: at, class: class} = entry, sites, defs) do
    case Enum.filter(sites, &(at(&1) == at)) do
      [] -> ["#{@allowlist}: #{name(at)} no longer raises: remove the entry"]
      found -> holds(class, at, found, defs, entry)
    end
  end

  defp holds(:bang, {module, function, arity} = at, _sites, defs, _entry) do
    words = Atom.to_string(function)
    twin = String.trim_trailing(words, "!")

    cond do
      not String.ends_with?(words, "!") ->
        ["#{@allowlist}: #{name(at)} is listed as :bang but its name doesn't end in `!`"]

      Enum.any?(
        defs,
        &(match?(%{module: ^module, kind: :def, arity: ^arity}, &1) and
              Atom.to_string(&1.function) == twin)
      ) ->
        []

      true ->
        [
          "#{@allowlist}: #{name(at)} is listed as :bang but #{inspect(module)}.#{twin}/#{arity} isn't defined"
        ]
    end
  end

  defp holds(:mix_task, {module, _f, _a} = at, _sites, _defs, _entry) do
    if String.starts_with?(inspect(module), "Mix.Tasks."),
      do: [],
      else: ["#{@allowlist}: #{name(at)} is listed as :mix_task but isn't in a Mix.Tasks module"]
  end

  # A raise in quoted code runs in the caller at run time, not while it compiles.
  defp holds(:compile, at, [site | _] = sites, _defs, _entry) do
    cond do
      site.kind not in [:defmacro, :defmacrop, nil] ->
        [
          "#{@allowlist}: #{name(at)} is listed as :compile but is a #{site.kind}, not a macro or the module body"
        ]

      quoted = Enum.find(sites, & &1.quoted) ->
        [
          "#{@allowlist}: #{name(at)} is listed as :compile but line #{quoted.line} raises in the code it generates, which runs in the caller"
        ]

      true ->
        []
    end
  end

  defp holds(:invariant, _at, _sites, _defs, _entry), do: []

  def main(argv) do
    dir =
      case argv do
        [] -> "."
        [dir] -> dir
      end

    allowlist = Path.join(dir, @allowlist)

    unless File.exists?(allowlist) do
      IO.puts("#{@allowlist} is missing: an empty list is `[]`")
      System.halt(1)
    end

    {entries, _} = Code.eval_file(allowlist)

    scans =
      for file <- Path.wildcard(Path.join(dir, "lib/**/*.ex")) |> Enum.sort(),
          do: {Path.relative_to(file, dir), scan(File.read!(file), Path.relative_to(file, dir))}

    {parsed, unparsed} = Enum.split_with(scans, &match?({_file, {:ok, _}}, &1))
    sites = parsed |> Enum.map(fn {_file, {:ok, scan}} -> length(scan.sites) end) |> Enum.sum()

    case Enum.map(unparsed, fn {_file, {:error, words}} -> words end) ++ problems(parsed, entries) do
      [] ->
        IO.puts("raises OK: #{sites} raise sites in lib/, every one in the allowlist")

      problems ->
        Enum.each(problems, &IO.puts/1)
        System.halt(1)
    end
  end
end

unless Application.get_env(:ci, :ci_no_main), do: Raises.main(System.argv())
