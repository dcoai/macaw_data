defmodule Macaw.Data.FormatTimeTest do
  @moduledoc """
  A time's format (spec/05 §5, #254). The conformance set is visualize's: every case of
  `Visualize.Format.time/2` in visualize's `test/visualize/axis_format_test.exs`, and its
  `%H:%M %Z` labels across New York's daylight-saving change in
  `test/visualize/scale/time_zone_test.exs`, each written here byte for byte as visualize
  writes it.
  """
  use ExUnit.Case, async: true

  alias Macaw.Data.{Error, Format}
  alias Macaw.Data.Format.Locale

  doctest Macaw.Data.Format.Time

  @dt DateTime.new!(~D[2024-03-03], ~T[14:05:09.123456], "Etc/UTC")

  defp time(value, pattern), do: Format.time(Format.parse_time!(pattern), value)

  # New York's wall clock at a UTC instant, as a zone database would give it: EDT until
  # 2026-11-01 06:00 UTC, EST from then.
  defp new_york(utc) do
    {abbr, std} =
      if DateTime.compare(utc, ~U[2026-11-01 06:00:00Z]) == :lt,
        do: {"EDT", 3600},
        else: {"EST", 0}

    local = DateTime.add(utc, -18_000 + std, :second)

    %{
      local
      | time_zone: "America/New_York",
        zone_abbr: abbr,
        utc_offset: -18_000,
        std_offset: std
    }
  end

  describe "conformance with visualize's Format.time/2 cases" do
    @tag verifies: "format-time-conformance"
    test "the eight original directives" do
      assert time(@dt, "%Y-%m-%d %H:%M:%S %b %B") == "2024-03-03 14:05:09 Mar March"
    end

    @tag verifies: "format-time-conformance"
    test "%% is a literal percent and one pass means no re-substitution" do
      assert time(@dt, "100%% %%Y %Y") == "100% %Y 2024"
    end

    @tag verifies: "format-time-conformance"
    test "the extended directives" do
      assert time(@dt, "%y %e %j %I %p %L %a %A %U %w %Z %z") ==
               "24  3 063 02 PM 123 Sun Sunday 09 0 UTC +0000"
    end

    @tag verifies: "format-time-conformance"
    test "midnight and noon under %I and %p" do
      assert time(~N[2024-01-01 00:30:00], "%I %p") == "12 AM"
      assert time(~N[2024-01-01 12:00:00], "%I %p") == "12 PM"
    end

    @tag verifies: "format-time-conformance"
    test "a Date has zero time fields and no zone; a NaiveDateTime has no zone" do
      assert time(~D[2024-12-25], "%H:%M:%S %L [%Z] [%z]") == "00:00:00 000 [] []"
      assert time(~D[2024-12-25], "%Y-%m-%d") == "2024-12-25"
      assert time(~N[2024-03-03 14:05:09], "%H%Z%z") == "14"
    end

    @tag verifies: "format-time-conformance"
    test "%U counts weeks from the first Sunday" do
      assert time(~D[2024-01-01], "%U") == "00"
      assert time(~D[2024-01-07], "%U") == "01"
    end

    @tag verifies: "format-time-conformance"
    test "an unknown directive and a trailing percent pass through" do
      assert time(@dt, "%Q %") == "%Q %"
    end

    @tag verifies: "format-time-conformance"
    test "a non-UTC offset, and New York's labels across the fall back" do
      dt =
        DateTime.new!(~D[2024-06-01], ~T[10:00:00], "Etc/UTC")
        |> Map.merge(%{utc_offset: -19_800, std_offset: 0, zone_abbr: "X"})

      assert time(dt, "%z %Z") == "-0530 X"

      hours =
        for h <- 4..8, do: new_york(DateTime.new!(~D[2026-11-01], Time.new!(h, 0, 0), "Etc/UTC"))

      assert Enum.map(hours, &time(&1, "%H:%M %Z")) == [
               "00:00 EDT",
               "01:00 EDT",
               "01:00 EST",
               "02:00 EST",
               "03:00 EST"
             ]

      quarters =
        for m <- [30, 45, 60, 75, 90],
            do: new_york(DateTime.add(~U[2026-11-01 05:00:00Z], m, :minute))

      assert Enum.map(quarters, &time(&1, "%H:%M %Z")) ==
               ["01:30 EDT", "01:45 EDT", "01:00 EST", "01:15 EST", "01:30 EST"]

      assert time(new_york(~U[2026-11-01 06:00:00Z]), "%H:%M %Z") == "01:00 EST"
    end
  end

  describe "every kind of time" do
    @tag verifies: "format-time-kinds"
    test "each kind is written by its own fields, an integer as UTC microseconds" do
      format = Format.parse_time!("%Y-%m-%d %H:%M:%S.%L %Z%z")
      zoned = new_york(~U[2026-07-04 16:00:00.250Z])

      assert Format.time(format, ~U[2026-07-04 16:00:00.250Z]) ==
               "2026-07-04 16:00:00.250 UTC+0000"

      assert Format.time(format, zoned) == "2026-07-04 12:00:00.250 EDT-0400"
      assert Format.time(format, ~N[2026-07-04 16:00:00.250]) == "2026-07-04 16:00:00.250 "
      assert Format.time(format, ~D[2026-07-04]) == "2026-07-04 00:00:00.000 "
      assert Format.time(format, 1_783_180_800_250_000) == "2026-07-04 16:00:00.250 UTC+0000"
      assert Format.time(format, -1) == "1969-12-31 23:59:59.999 UTC+0000"
    end

    @tag verifies: "format-time-kinds"
    test "any other value, and an integer past a DateTime's range, is NaN" do
      format = Format.parse_time!("%Y")

      for value <- [nil, "2026-01-01", 1.5, :now, ~T[10:00:00], %{year: 2026}, 10 ** 30],
          do: assert(Format.time(format, value) == "NaN")

      assert Format.time(Format.parse_time!("%Y", locale: Locale.new!(nan: "—")), nil) == "—"
    end

    @tag verifies: "format-time-kinds"
    test "another locale's periods, days and months are written" do
      fr =
        Locale.new!(
          periods: ["AM", "PM"],
          days: ~w(dimanche lundi mardi mercredi jeudi vendredi samedi),
          short_days: ~w(dim. lun. mar. mer. jeu. ven. sam.),
          months:
            ~w(janvier février mars avril mai juin juillet août septembre octobre novembre décembre),
          short_months: ~w(janv. févr. mars avr. mai juin juil. août sept. oct. nov. déc.)
        )

      format = Format.parse_time!("%A %e %B %Y, %a %b", locale: fr)
      assert Format.time(format, ~D[2026-02-01]) == "dimanche  1 février 2026, dim. févr."
      assert Format.time(format, ~D[2026-08-15]) == "samedi 15 août 2026, sam. août"

      twelve = Format.parse_time!("%I %p", locale: Locale.new!(periods: ["a.m.", "p.m."]))
      assert Format.time(twelve, ~N[2026-01-01 15:00:00]) == "03 p.m."
    end

    @tag verifies: "format-time-kinds"
    test "parse_time/2 refuses a term that is no string and options parse/2 refuses" do
      assert Format.parse_time(1) == {:error, [{[], {:type, :pattern}}]}
      assert Format.parse_time("%Y", locale: "fr") == {:error, [{[:locale], {:type, :locale}}]}

      assert Format.parse_time(nil, typo: 1) ==
               {:error, [{[], {:type, :pattern}}, {[:typo], :unknown_key}]}

      assert {:ok, %Format.Time{pattern: ""}} = Format.parse_time("")
      assert Format.time(Format.parse_time!(""), @dt) == ""

      error = assert_raise Error, fn -> Format.parse_time!(:iso) end
      assert error.reason == [{[], {:type, :pattern}}]

      assert Exception.message(error) ==
               "not a time format: value: must be a strftime pattern, a string"
    end

    @tag verifies: "format-time-kinds"
    test "a locale's names are lists of 2, 7 and 12 strings" do
      assert Locale.new(periods: ["am"], days: Enum.map(1..7, &to_string/1), months: [1 | 2]) ==
               {:error, [{[:periods], {:names, 2}}, {[:months], {:names, 12}}]}

      assert Format.format_error({:names, 7}) == "must be a list of 7 strings"
    end
  end
end
