defmodule Macaw.Data.Checked do
  @moduledoc false
  # A step's arithmetic, total: the BEAM's answer, or `:overflow` exactly where the BEAM
  # would raise (spec/04 §4.8, §5, macaw_data#178, #181). A float has no infinity here,
  # so a result past the largest float is `ArithmeticError`, and so is an integer past it beside a
  # float or under a division. `:overflow` passes through every operation, so a sum can
  # run to its end and be read for it once.
  #
  # Below the screens no result can pass the largest float, and the operation runs as it
  # is. Above them the exact result decides, on `Float.ratio/1`'s exact fractions: a float
  # result rounds to nearest, so it overflows at `@rounds_up`, half a unit past the
  # largest float.

  @typedoc "A number, or what a sum past a float's range left."
  @type t :: number() | :overflow

  @half 8.0e307
  @root 1.0e150
  @largest Integer.pow(2, 1024) - Integer.pow(2, 971)
  @rounds_up Integer.pow(2, 1024) - Integer.pow(2, 970)

  @doc false
  @spec add(t(), t()) :: t()
  def add(a, b) when is_integer(a) and is_integer(b), do: a + b

  def add(a, b) when is_number(a) and is_number(b) and abs(a) < @half and abs(b) < @half,
    do: a + b

  def add(a, b) when is_number(a) and is_number(b) do
    if float?(a) and float?(b) do
      {an, ad} = Float.ratio(a * 1.0)
      {bn, bd} = Float.ratio(b * 1.0)
      if abs(an * bd + bn * ad) < @rounds_up * ad * bd, do: a + b, else: :overflow
    else
      :overflow
    end
  end

  def add(_a, _b), do: :overflow

  @doc false
  @spec negate(t()) :: t()
  def negate(a) when is_number(a), do: -a
  def negate(:overflow), do: :overflow

  @doc false
  @spec subtract(t(), t()) :: t()
  def subtract(a, b), do: add(a, negate(b))

  @doc false
  @spec multiply(t(), t()) :: t()
  def multiply(a, b) when is_integer(a) and is_integer(b), do: a * b

  def multiply(a, b) when is_number(a) and is_number(b) and abs(a) < @root and abs(b) < @root,
    do: a * b

  def multiply(a, b) when is_number(a) and is_number(b) do
    if float?(a) and float?(b) do
      {an, ad} = Float.ratio(a * 1.0)
      {bn, bd} = Float.ratio(b * 1.0)
      if abs(an * bn) < @rounds_up * ad * bd, do: a * b, else: :overflow
    else
      :overflow
    end
  end

  def multiply(_a, _b), do: :overflow

  @doc false
  # `b` is never zero: each caller asks first.
  @spec divide(t(), t()) :: t()
  def divide(a, b)
      when is_number(a) and is_number(b) and abs(a) < @half and abs(b) >= 1 and abs(b) < @half,
      do: a / b

  def divide(a, b) when is_number(a) and is_number(b) do
    if float?(a) and float?(b) do
      {an, ad} = Float.ratio(a * 1.0)
      {bn, bd} = Float.ratio(b * 1.0)
      if abs(an * bd) < @rounds_up * ad * abs(bn), do: a / b, else: :overflow
    else
      :overflow
    end
  end

  def divide(_a, _b), do: :overflow

  # Whether a number reads as a float: a float does, and an integer up to the largest one.
  defp float?(a) when is_float(a), do: true
  defp float?(a), do: abs(a) <= @largest
end
