# Sample offsets are silently wrong when a free/skip/unknown box sits between moof and mdat.
#
# Demuxer.CMAF.Engine tracks how_many_segment_bytes_read, i.e. how many bytes have passed since
# the start of the moof, because trun sample offsets are counted from there. Boxes the engine
# ignores (:free, :skip and :unknown - any box type the schema does not know) were skipped
# without advancing that counter, so the start of the mdat content was understated by their size
# and every payload was read from the wrong place, with no error raised.
#
# The trun below carries an ordinary literal sample list, i.e. the path the sample_count fix does
# not touch, so this reproduces independently of it.
#
# Run it with `elixir repro_free_box.exs`; it builds the plugin from this checkout, not from hex.
Mix.install([:membrane_core, {:membrane_mp4_plugin, path: __DIR__}])

alias Membrane.MP4.Demuxer.CMAF.Engine

box = fn type, body -> <<8 + byte_size(body)::32, type::binary, body::binary>> end
header = File.read!(Path.join(__DIR__, "test/fixtures/cmaf/ref_audio_header.mp4"))

tfhd = box.("tfhd", <<0::8, 0x08::24, 1::32, 1000::32>>)
tfdt = box.("tfdt", <<1::8, 0::24, 0::64>>)
free = box.("free", <<9, 9, 9, 9>>)

# trun fo_flags = 0x201: data_offset present, plus a per-sample sample_size for each of 3 samples
moof = fn data_offset ->
  trun = box.("trun", <<0::8, 0x201::24, 3::32, data_offset::signed-32, 4::32, 4::32, 4::32>>)
  box.("moof", box.("traf", tfhd <> tfdt <> trun))
end

# data_offset per ISO/IEC 14496-12: the first byte of the mdat content, counted from the start of
# the moof - so it has to include the free box sitting in between
data_offset = byte_size(moof.(0)) + byte_size(free) + 8

# the 12 bytes of filler are what a demuxer that ignores the free box reads instead
mdat = box.("mdat", <<1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3>> <> :binary.copy(<<7>>, 12))

expected = [<<1, 1, 1, 1>>, <<2, 2, 2, 2>>, <<3, 3, 3, 3>>]

payloads =
  try do
    {:ok, samples, _engine} =
      Engine.new()
      |> Engine.feed!(header)
      |> Engine.feed!(moof.(data_offset) <> free <> mdat)
      |> Engine.pop_samples()

    Enum.map(samples, & &1.payload)
  rescue
    error -> {:crash, Exception.message(error) |> String.slice(0, 90)}
  end

IO.puts("expected: #{inspect(expected)}")
IO.puts("got:      #{inspect(payloads)}")

if payloads == expected do
  IO.puts("PASSED: the free box was counted, payloads read from the right offsets")
else
  IO.puts("FAILED: the free box was not counted, so every sample was read from the wrong offset")
  System.halt(1)
end
