defmodule Macaw.Data.Error do
  @moduledoc """
  What every `!` twin raises (spec/00 §5): its value twin's `{:error, reason}`, with the
  reason's term kept and its words for the message.

  `reason` is the term exactly as the twin answers it, a list of `{path, reason}` faults or
  one bare reason, so a caller that catches nothing still reads the terms in a crash
  report, and a test asserts them without parsing words:

      iex> error = Macaw.Data.Error.exception(reason: [{[:temp], {:length, 3}}], what: "not a table")
      iex> {error.reason, Exception.message(error)}
      {[{[:temp], {:length, 3}}], "not a table: temp: must hold 3 values, as the first column does"}

  `exception/1` takes `reason:` and words it with `Macaw.Data.Fault.sentence/2`, passing
  `root:` and `words:` along. `what:` names what the input is not, and starts the message.
  A twin whose module already words its reasons gives the message whole, as `message:`.
  """

  defexception [:reason, :message]

  @type t :: %__MODULE__{reason: term(), message: String.t()}

  @impl true
  def exception(opts) when is_list(opts) do
    reason = Keyword.get(opts, :reason)

    message =
      case Keyword.get(opts, :message) do
        nil ->
          lead(opts[:what]) <>
            Macaw.Data.Fault.sentence(reason, Keyword.take(opts, [:root, :words]))

        message ->
          message
      end

    %__MODULE__{reason: reason, message: message}
  end

  defp lead(nil), do: ""
  defp lead(what), do: what <> ": "
end
