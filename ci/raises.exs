# Errors are values (spec/00 §5, #114): fails on a `raise` in lib/ outside the
# allowed places.
#
#     elixir ci/raises.exs          # report and exit 1 on any problem
#
# A public function answers bad input with `{:error, reason}`; it does not raise. The
# check reads every `.ex` file under `lib/` as code (`Code.string_to_quoted/2`, so a
# `raise` in a doc or a comment is no site) and finds each `raise`, `reraise` and `throw`
# with the function it sits in, `Module.name/arity`. A site passes when:
#
# - it is in a public `name!` function whose module also defines `name` of the same
#   arity: the bang twin, which raises its twin's `{:error, _}` (found, never listed);
# - or the allowlist `ci/raises_allowlist.exs` names its function, with how many sites
#   the function holds, the site's class and its reason.
#
# The classes:
#
#   :bang       a private helper the bang twins share to raise their twin's reason
#   :compile    a macro's misuse, which fails the build: there is no caller to answer
#   :invariant  a broken internal invariant: a bug in this library, never bad input
#   :convert    bad input still answered with a raise, while the "Errors are values"
#               milestone (#114) lasts: its reason names the issue that converts it
#
# An entry whose function holds a different number of sites fails too, so the list
# cannot go stale. Its test loads this file with `:ci_no_main` set, so nothing runs on
# load.

defmodule RaiseGate do
  @scanned "lib"
  @allowlist "ci/raises_allowlist.exs"
  @classes [:bang, :compile, :invariant, :convert]
  @defs [:def, :defp, :defmacro, :defmacrop]
  @raising [:raise, :reraise, :throw]

  @doc "Every problem under `root`, one line each; `[]` when there is none."
  def run(root) do
    {entries, _binding} = root |> Path.join(@allowlist) |> Code.eval_file()
    run(root, entries)
  end

  @doc "The check against a given allowlist."
  def run(root, entries) do
    sites = sites(root)
    # A malformed entry is reported once, and allows nothing.
    {formed, malformed} = Enum.split_with(entries, &is_nil(malformed_entry(&1)))
    malformed(malformed) ++ unallowed(sites, formed) ++ stale(sites, formed)
  end

  @doc "Every `{file, line, site, twin?}` under `root`: each raise and the function it is in."
  def sites(root) do
    root
    |> Path.join(@scanned <> "/**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      file = Path.relative_to(path, root)
      {:ok, ast} = path |> File.read!() |> Code.string_to_quoted(file: file, columns: false)

      file_sites =
        for line <- raises(ast), do: {file, line, "#{file} (file body)", false}

      file_sites ++ (ast |> modules(nil) |> Enum.flat_map(&module_sites(file, &1)))
    end)
  end

  # Every `{module_name, body}` in `ast`, wherever it is defined (a module defined under
  # a compile-time `case` too), nested modules named in full.
  defp modules(ast, outer) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [alias, [do: body]]}, acc ->
          name = join(outer, Macro.to_string(alias))
          {:skipped, [[{name, body} | modules(body, name)] | acc]}

        node, acc ->
          {node, acc}
      end)

    found |> Enum.reverse() |> Enum.concat()
  end

  defp join(nil, name), do: name
  defp join(outer, name), do: outer <> "." <> name

  defp module_sites(file, {module, body}) do
    forms = forms(body)
    public = for {kind, name, arity, _} <- forms, kind in [:def, :defmacro], do: {name, arity}

    Enum.flat_map(forms, fn {kind, name, arity, form} ->
      for line <- raises(form) do
        bang = String.ends_with?(name, "!")
        twin? = kind == :def and bang and {String.trim_trailing(name, "!"), arity} in public
        {file, line, "#{module}.#{name}/#{arity}", twin?}
      end
    end) ++
      for line <- raises(module_level(body)), do: {file, line, "#{module} (module body)", false}
  end

  # Every `{kind, name, arity, form}` defined directly in a module's body.
  defp forms({:__block__, _, forms}), do: Enum.flat_map(forms, &forms([&1]))
  defp forms([{kind, _, [head | _]} = form]) when kind in @defs, do: [head(kind, head, form)]
  defp forms([_]), do: []
  defp forms(form), do: forms([form])

  defp head(kind, {:when, _, [head, _guard]}, form), do: head(kind, head, form)

  defp head(kind, {name, _, args}, form) when is_atom(name) do
    {kind, Atom.to_string(name), length(List.wrap(args)), form}
  end

  # A module's own code outside any function and outside nested modules: run as it compiles.
  defp module_level({:__block__, _, forms}), do: Enum.reject(forms, &skipped?/1)
  defp module_level(form), do: if(skipped?(form), do: [], else: [form])

  defp skipped?({kind, _, _}) when kind in [:defmodule | @defs], do: true
  defp skipped?(_), do: false

  # The line of every raising call in `form`, nested modules left to their own entry.
  defp raises(form) do
    {_, lines} =
      Macro.prewalk(form, [], fn
        {:defmodule, _, _}, acc ->
          {:skipped, acc}

        {call, meta, args} = node, acc when call in @raising and is_list(args) ->
          {node, [meta[:line] | acc]}

        {{:., _, [{:__aliases__, _, [:Kernel]}, call]}, meta, args} = node, acc
        when call in @raising and is_list(args) ->
          {node, [meta[:line] | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(lines)
  end

  defp malformed(entries) do
    for entry <- entries, problem = malformed_entry(entry), do: problem
  end

  defp malformed_entry(%{site: site, count: count, class: class, reason: reason} = entry)
       when is_binary(site) and is_integer(count) and count > 0 and class in @classes and
              is_binary(reason) and reason != "",
       do: if(class == :convert and not (reason =~ ~r/#\d+/), do: unnamed(entry))

  defp malformed_entry(entry),
    do:
      "#{@allowlist}: an entry needs site, count, a class of #{inspect(@classes)} and a " <>
        "reason; got #{inspect(entry)}"

  defp unnamed(entry),
    do: "#{@allowlist}: a :convert entry names the issue that converts it; got #{inspect(entry)}"

  defp unallowed(sites, entries) do
    listed = MapSet.new(entries, & &1.site)

    for {file, line, site, false} <- sites,
        site not in listed,
        do: "#{file}:#{line}: #{site} raises; answer {:error, reason} instead"
  end

  defp stale(sites, entries) do
    for %{site: site, count: count} <- entries,
        held = Enum.count(sites, fn {_, _, s, twin?} -> s == site and not twin? end),
        held != count,
        do: "#{@allowlist}: #{site} holds #{held} raise(s), the entry says #{count}"
  end

  def main do
    case run(File.cwd!()) do
      [] ->
        IO.puts("raises OK: no raise in lib/ outside the bang twins and the allowlist")

      problems ->
        Enum.each(problems, &IO.puts/1)
        System.halt(1)
    end
  end
end

unless Application.get_env(:ci, :ci_no_main), do: RaiseGate.main()
