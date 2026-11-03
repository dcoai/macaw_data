defmodule Macaw.Data.FFT do
  @moduledoc """
  The fast Fourier transform of a real or complex sequence (spec/04 §4.11): a radix-2
  Cooley–Tukey decimation in time over lists, `O(N log N)`, pure Elixir. The engine of the
  `spectrum` transform, ported from visualize's `Visualize.Data.FFT`.

  A time series becomes its frequency spectrum through `spectrum/3`: the newest power of
  two of samples, tapered by a window, transformed, and read as one-sided amplitudes —
  what the `spectrum` transform of spec/04 §4.11 answers.

      iex> Macaw.Data.FFT.fft!([1, 0, 0, 0])
      [{1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}, {1.0, 0.0}]
  """

  @typedoc "A complex number as `{re, im}`."
  @type complex :: {float(), float()}

  @typedoc "One line of a spectrum."
  @type line :: %{frequency: float(), magnitude: float(), phase: float()}

  @windows [:hann, :hamming, :none]

  @doc "The window functions `window/2` applies, `:hann` first."
  @spec windows() :: [atom(), ...]
  def windows, do: @windows

  @doc """
  The discrete Fourier transform of a sequence whose length is a power of two: numbers
  are taken as real, `{re, im}` pairs as complex, `{:ok, terms}`. Any other length is
  `{:error, {:samples, n}}`, and a term that is neither `{:error, {:values, :number}}`
  (spec/00 §5); `fft!/1` answers the terms or raises.

      iex> {:ok, terms} = Macaw.Data.FFT.fft([0, 1, 0, -1])
      iex> Enum.map(terms, fn {re, im} -> {Float.round(re, 9) + 0.0, Float.round(im, 9) + 0.0} end)
      [{0.0, 0.0}, {0.0, -2.0}, {0.0, 0.0}, {0.0, 2.0}]
      iex> Macaw.Data.FFT.fft([1, 2, 3])
      {:error, {:samples, 3}}
  """
  @spec fft([number() | complex()]) :: {:ok, [complex()]} | {:error, reason()}
  def fft(sequence) when is_list(sequence) do
    n = length(sequence)

    cond do
      not power_of_two?(n) -> {:error, {:samples, n}}
      not Enum.all?(sequence, &term?/1) -> {:error, {:values, :number}}
      true -> {:ok, sequence |> Enum.map(&complex/1) |> transform(n)}
    end
  end

  def fft(_sequence), do: {:error, {:values, :number}}

  @doc "As `fft/1`, the terms alone, raising `Macaw.Data.Error` in `format_error/1`'s words."
  @spec fft!([number() | complex()]) :: [complex()]
  def fft!(sequence) do
    case fft(sequence) do
      {:ok, value} -> value
      {:error, reason} -> raise error(reason)
    end
  end

  @typedoc "Why a transform or a spectrum is refused (`format_error/1`)."
  @type reason ::
          {:samples, term()} | {:window, term()} | {:every, term()} | {:values, :number}

  @doc """
  A refusal's words.

      iex> Macaw.Data.FFT.format_error({:samples, 12})
      "the FFT takes a power of two of samples, not 12"
  """
  @spec format_error(reason()) :: String.t()
  def format_error({:samples, n}),
    do: "the FFT takes a power of two of samples, not #{inspect(n)}"

  def format_error({:window, kind}),
    do: "window is one of #{inspect(@windows)}, not #{inspect(kind)}"

  def format_error({:every, every}),
    do: "every is the seconds between samples, above zero, not #{inspect(every)}"

  def format_error({:values, :number}), do: "every value is a number, or a complex {re, im}"

  defp term?(n) when is_number(n), do: true
  defp term?({re, im}) when is_number(re) and is_number(im), do: true
  defp term?(_other), do: false

  # What the bang twins raise: their twin's reason, and its words (spec/00 §5).
  defp error(reason),
    do: Macaw.Data.Error.exception(reason: reason, message: format_error(reason))

  @doc "The magnitude `sqrt(re² + im²)` of every term."
  @spec magnitudes([complex()]) :: [float()]
  def magnitudes(terms), do: Enum.map(terms, fn {re, im} -> :math.sqrt(re * re + im * im) end)

  @doc """
  The sequence tapered by a window: `:hann` (`0.5 − 0.5 cos(2πi/(N−1))`), `:hamming`
  (`0.54 − 0.46 cos(2πi/(N−1))`) or `:none`; a sequence shorter than four is not tapered.

      iex> Macaw.Data.FFT.window([1, 1, 1, 1, 1], :hann) |> Enum.map(&Float.round(&1, 3))
      [0.0, 0.5, 1.0, 0.5, 0.0]
  """
  @spec window([number()], atom()) :: [float()]
  def window(values, :none), do: Enum.map(values, &(&1 * 1.0))

  def window(values, kind) when kind in @windows do
    n = length(values)
    {a, b} = if kind == :hann, do: {0.5, 0.5}, else: {0.54, 0.46}

    # A sequence shorter than four is not tapered: the Hann of two points is all zeros.
    if n < 4 do
      window(values, :none)
    else
      values
      |> Enum.with_index()
      |> Enum.map(fn {v, i} -> v * (a - b * :math.cos(2 * :math.pi() * i / (n - 1))) end)
    end
  end

  @doc """
  The one-sided amplitude spectrum of a series sampled every `every` seconds: the newest
  `samples` values (the largest power of two not above the count when not given), tapered
  by `window` (`:hann`), transformed, and read as `samples / 2` lines — `frequency` is
  `k / (samples · every)` hertz, `magnitude` the amplitude `|X_k| · 2 / (samples · gain)`
  with the window's mean gain divided out (the DC line not doubled), `phase` the argument
  of `X_k`, as `{:ok, lines}`. Fewer than two values yield `{:ok, []}`. A refusal is
  `{:error, reason}` (spec/00 §5): `{:samples, s}`, `{:window, kind}`, `{:every, every}`
  or `{:values, :number}`; `spectrum!/3` answers the lines or raises.

  ## Options

    * `:samples` - the window length, a power of two
    * `:window` - one of `windows/0` (default `:hann`)
    * `:detrend` - subtract the window's mean before transforming, so an offset does not
      leak from the DC line into its neighbors (default `false`)

      iex> every = 1 / 64
      iex> values = for i <- 0..63, do: :math.sin(2 * :math.pi() * 8 * i * every)
      iex> {:ok, lines} = Macaw.Data.FFT.spectrum(values, every, window: :none)
      iex> peak = Enum.max_by(lines, & &1.magnitude)
      iex> {length(lines), Float.round(peak.frequency, 6), Float.round(peak.magnitude, 6)}
      {32, 8.0, 1.0}
  """
  @spec spectrum([number()], number(), keyword()) :: {:ok, [line()]} | {:error, reason()}
  def spectrum(values, every, opts \\ []) do
    samples =
      is_list(values) && (Keyword.get(opts, :samples) || largest_power_of_two(length(values)))

    kind = Keyword.get(opts, :window, :hann)

    cond do
      not (is_list(values) and Enum.all?(values, &is_number/1)) -> {:error, {:values, :number}}
      not (is_number(every) and every > 0) -> {:error, {:every, every}}
      not (samples == nil or power_of_two?(samples)) -> {:error, {:samples, samples}}
      kind not in @windows -> {:error, {:window, kind}}
      true -> {:ok, lines(values, every, samples, kind, opts)}
    end
  end

  @doc "As `spectrum/3`, the lines alone, raising `Macaw.Data.Error` in `format_error/1`'s words."
  @spec spectrum!([number()], number(), keyword()) :: [line()]
  def spectrum!(values, every, opts \\ []) do
    case spectrum(values, every, opts) do
      {:ok, value} -> value
      {:error, reason} -> raise error(reason)
    end
  end

  defp lines(values, every, samples, kind, opts) do
    count = length(values)

    if samples == nil or samples < 2 or count < samples do
      []
    else
      taken = values |> Enum.take(-samples) |> Enum.map(&(&1 * 1.0))
      taken = if Keyword.get(opts, :detrend, false), do: detrended(taken), else: taken
      gain = window_gain(samples, kind)

      taken
      |> window(kind)
      |> Enum.map(&complex/1)
      |> transform(samples)
      |> Enum.take(div(samples, 2))
      |> Enum.with_index()
      |> Enum.map(fn {{re, im}, k} ->
        scale = if k == 0, do: 1 / (samples * gain), else: 2 / (samples * gain)

        %{
          frequency: k / (samples * every),
          magnitude: :math.sqrt(re * re + im * im) * scale,
          phase: :math.atan2(im, re)
        }
      end)
    end
  end

  # -- the transform ----------------------------------------------------------------------

  defp transform([x], 1), do: [x]

  defp transform(terms, n) do
    {evens, odds} = split(terms, [], [])
    half = div(n, 2)
    e = transform(evens, half)
    o = transform(odds, half)

    twiddled =
      o
      |> Enum.with_index()
      |> Enum.map(fn {{re, im}, k} ->
        angle = -2 * :math.pi() * k / n
        {c, s} = {:math.cos(angle), :math.sin(angle)}
        {re * c - im * s, re * s + im * c}
      end)

    first = Enum.zip_with(e, twiddled, fn {a, b}, {c, d} -> {a + c, b + d} end)
    second = Enum.zip_with(e, twiddled, fn {a, b}, {c, d} -> {a - c, b - d} end)
    first ++ second
  end

  defp split([], evens, odds), do: {Enum.reverse(evens), Enum.reverse(odds)}
  defp split([e], evens, odds), do: {Enum.reverse([e | evens]), Enum.reverse(odds)}
  defp split([e, o | rest], evens, odds), do: split(rest, [e | evens], [o | odds])

  defp complex({re, im}) when is_number(re) and is_number(im), do: {re * 1.0, im * 1.0}
  defp complex(re) when is_number(re), do: {re * 1.0, 0.0}

  defp power_of_two?(n) when is_integer(n) and n > 0, do: Bitwise.band(n, n - 1) == 0
  defp power_of_two?(_n), do: false

  defp largest_power_of_two(count) when count < 1, do: nil

  defp largest_power_of_two(count) do
    1 |> Stream.iterate(&(&1 * 2)) |> Enum.take_while(&(&1 <= count)) |> List.last()
  end

  defp detrended(values) do
    mean = Enum.sum(values) / length(values)
    Enum.map(values, &(&1 - mean))
  end

  # The mean of the window, which the amplitudes are divided by so a sine's line reads
  # its amplitude whatever the taper.
  defp window_gain(_samples, :none), do: 1.0

  defp window_gain(samples, kind),
    do: Enum.sum(window(List.duplicate(1.0, samples), kind)) / samples
end
