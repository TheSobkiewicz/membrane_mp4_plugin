# A trun without the data-offset-present flag, ISO/IEC 14496-12 8.8.8.
#
# The flag is optional. A run that omits it starts immediately after the previous run's data, or
# at base_data_offset if it is the first run of the track fragment. Reading fields.data_offset
# unconditionally raises KeyError on such a trun, and defaulting the missing offset to 0 is only
# correct for the first run - the second one then lands back on base_data_offset and reads the
# first run's bytes.
#
# Two truns of two samples each, the second one flagless, over an mdat holding four 4-byte
# samples laid out back to back.
#
# Run it with `elixir repro_trun_data_offset.exs`; it builds the plugin from this checkout.
Mix.install([:membrane_core, {:membrane_mp4_plugin, path: __DIR__}])

alias Membrane.MP4.Demuxer.CMAF.Engine

box = fn type, body -> <<8 + byte_size(body)::32, type::binary, body::binary>> end
header = File.read!(Path.join(__DIR__, "test/fixtures/cmaf/ref_audio_header.mp4"))

# tfhd flags 0x18: default_sample_duration + default_sample_size, so the truns need no per-sample
# fields of their own
tfhd = box.("tfhd", <<0::8, 0x18::24, 1::32, 1000::32, 4::32>>)
tfdt = box.("tfdt", <<1::8, 0::24, 0::64>>)

moof = fn data_offset ->
  first = box.("trun", <<0::8, 0x1::24, 2::32, data_offset::signed-32>>)
  second = box.("trun", <<0::8, 0::24, 2::32>>)
  box.("moof", box.("traf", tfhd <> tfdt <> first <> second))
end

# only the first run says where it starts; the second has to continue after it
data_offset = byte_size(moof.(0)) + 8
mdat = box.("mdat", <<1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4>>)

expected = [<<1, 1, 1, 1>>, <<2, 2, 2, 2>>, <<3, 3, 3, 3>>, <<4, 4, 4, 4>>]

payloads =
  try do
    {:ok, samples, _engine} =
      Engine.new()
      |> Engine.feed!(header)
      |> Engine.feed!(moof.(data_offset) <> mdat)
      |> Engine.pop_samples()

    Enum.map(samples, & &1.payload)
  rescue
    error ->
      {:crash,
       "#{inspect(error.__struct__)} - #{Exception.message(error) |> String.slice(0, 70)}"}
  end

IO.puts("expected: #{inspect(expected)}")
IO.puts("got:      #{inspect(payloads)}")

if payloads == expected do
  IO.puts("PASSED: the flagless run continued after the first run's data")
else
  IO.puts("FAILED: a trun without data-offset-present is not handled per ISO/IEC 14496-12 8.8.8")
  System.halt(1)
end
