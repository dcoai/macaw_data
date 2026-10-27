defmodule Macaw.Data.Derived.Functions do
  @moduledoc """
  A host's derived-source functions (spec/02 §7), written as Elixir in the host's own
  module and tested with ExUnit:

      defmodule MyApp.Sources do
        use Macaw.Data.Derived.Functions

        defsource health(rows) do
          cpu = Enum.map(rows, & &1.cpu)
          %{state: if(List.last(cpu) > 90, do: :error, else: :ok)}
        end

        defsource bins(inputs, context) do
          %{"bounds" => [lo, hi]} = context["inputs"]["hosts"]["schema"]["cpu"]
          ...
        end
      end

  `use Macaw.Data.Derived.Functions` imports `defsource/2` and compiles `__derived__/0`,
  each function's name, its arity and its source text, `[{name, arity, source}]` in
  definition order. A function of two arguments is called with its inputs and its context
  (spec/02 §2.3), one of one argument with its inputs alone. The text is captured when the
  module compiles, since a release strips the debug information a later reading would need.

  A host's function is trusted (the sandbox's checker does not read it), but it runs
  through the same bounded runner as a stored one (`Macaw.Data.Derived.Sandbox.run/3`), so
  a runaway ends as a fault, not as its owner's crash. A derived source names it with
  `function: :health`; the host passes the module to the registry explicitly, and nothing
  else registers one: no application environment is read.

  Ported from visualize's `Visualize.VirtualSources`.

  ## Examples

      iex> defmodule Doc.Sources do
      ...>   use Macaw.Data.Derived.Functions
      ...>   defsource doubled(rows), do: Enum.map(rows, &(&1 * 2))
      ...> end
      iex> Doc.Sources.doubled([1, 2])
      [2, 4]
      iex> Doc.Sources.__derived__()
      [{:doubled, 1, "fn rows -> Enum.map(rows, &(&1 * 2)) end"}]
      iex> Macaw.Data.Derived.Functions.registry([Doc.Sources])
      %{"doubled" => {Doc.Sources, 1}}
  """

  @typedoc "Each host function's name, its string, by the module that defines it and its arity."
  @type registry :: %{String.t() => {module(), 1 | 2}}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Macaw.Data.Derived.Functions, only: [defsource: 2]
      Module.register_attribute(__MODULE__, :macaw_derived_functions, accumulate: true)
      @before_compile Macaw.Data.Derived.Functions
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    clauses =
      env.module
      |> Module.get_attribute(:macaw_derived_functions)
      |> Enum.reverse()

    sources =
      clauses
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.map(fn name ->
        fns = for {^name, _arity, clause} <- clauses, do: clause
        {name, arity!(name, clauses, env), Macro.to_string({:fn, [], fns})}
      end)

    quote do
      @doc false
      def __derived__, do: unquote(Macro.escape(sources))
    end
  end

  # One name, one arity: the engine calls a function by the arity recorded for its name.
  defp arity!(name, clauses, env) do
    case clauses
         |> Enum.flat_map(fn {n, a, _c} -> if n == name, do: [a], else: [] end)
         |> Enum.uniq() do
      [arity] ->
        arity

      arities ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "defsource #{name} has clauses of #{Enum.map_join(arities, " and ", &to_string/1)} " <>
              "arguments; one function takes its inputs, or its inputs and its context"
    end
  end

  @doc """
  A host's derived-source function: `defsource name(inputs) do … end` is a public `def` of
  one argument, and `defsource name(inputs, context) do … end` one of two, which is called
  with its context (spec/02 §2.3); either is recorded with its arity and source text under
  the module's `__derived__/0`. A function of several clauses is
  defined clause by clause, as any function is, and listed once with every clause.
  """
  defmacro defsource(head, body) do
    {name, args, guard} = head!(head, __CALLER__)
    block = body!(body, __CALLER__)
    patterns = if guard, do: [{:when, [], args ++ [guard]}], else: args
    clause = Macro.escape({:->, [], [patterns, block]})

    quote do
      @macaw_derived_functions {unquote(name), unquote(length(args)), unquote(clause)}
      def unquote(head), unquote(body)
    end
  end

  defp head!({:when, _meta, [head, guard]}, caller) do
    {name, args, nil} = head!(head, caller)
    {name, args, guard}
  end

  defp head!({name, _meta, [_arg] = args}, _caller) when is_atom(name), do: {name, args, nil}

  defp head!({name, _meta, [_inputs, _context] = args}, _caller) when is_atom(name),
    do: {name, args, nil}

  defp head!(head, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "defsource needs a head of one argument, `name(inputs)`, or two, " <>
          "`name(inputs, context)`, as a stored function takes; got #{Macro.to_string(head)}"
  end

  defp body!([do: block], _caller), do: block

  defp body!(body, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "defsource takes a do block alone; got #{Macro.to_string(body)}"
  end

  @doc """
  The registry of `modules` (spec/02 §7): each function's name, its string, by the module
  that defines it and its arity. Default closed: only the modules given are read. Raises
  `ArgumentError` for a module without `__derived__/0` and for a name two modules define.
  """
  @spec registry([module()]) :: registry()
  def registry(modules) when is_list(modules) do
    modules
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn module, registry ->
      module
      |> functions!()
      |> Enum.reduce(registry, fn {name, arity, _source}, registry ->
        register(registry, Atom.to_string(name), {module, arity})
      end)
    end)
  end

  defp functions!(module) do
    if is_atom(module) and Code.ensure_loaded?(module) and
         function_exported?(module, :__derived__, 0) do
      module.__derived__()
    else
      raise ArgumentError,
            "#{inspect(module)} is not a derived-source function module: " <>
              "`use Macaw.Data.Derived.Functions` defines __derived__/0 (spec/02 §7)"
    end
  end

  defp register(registry, name, {module, _arity} = entry) do
    case Map.fetch(registry, name) do
      :error ->
        Map.put(registry, name, entry)

      {:ok, {other, _arity}} ->
        raise ArgumentError,
              "derived-source function #{name} is defined by both #{inspect(other)} and " <>
                "#{inspect(module)}: a derived source names one function (spec/02 §7)"
    end
  end
end
