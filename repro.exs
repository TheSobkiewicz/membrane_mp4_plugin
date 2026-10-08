# A ~400 MB per-process heap cap (kill: true) is installed first, so the demuxer is killed in a
# few seconds instead of swapping the host; the unhandled crash then takes the linked pipeline
# and this script down.
#
# Run it with `elixir repro.exs`; it builds the plugin from this checkout, not from hex.
Mix.install([:membrane_core, {:membrane_mp4_plugin, path: __DIR__}])

Logger.configure(level: :error)

sample_count = 100_000_000
:erlang.system_flag(:max_heap_size, %{size: 50_000_000, kill: true, error_logger: false})

box = fn type, body -> <<8 + byte_size(body)::32, type::binary, body::binary>> end
trun = box.("trun", <<0::8, 0::24, sample_count::32>>)
fragment = box.("moof", box.("traf", trun))

defmodule Repro do
  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, fragment) do
    spec =
      child(:source, %Membrane.Testing.Source{
        output: [fragment],
        stream_format: %Membrane.RemoteStream{type: :bytestream}
      })
      |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)

    {[spec: spec], %{}}
  end
end

IO.puts("#{byte_size(fragment)}-byte fragment, declared sample_count = #{sample_count}")
IO.puts("starting pipeline; on vulnerable code the demuxer allocates until it is killed")

# The pipeline is linked, so trapping exits is what lets this script report the outcome instead
# of dying along with it: a heap-cap kill means the declared sample_count was expanded, anything
# else (a rejected fragment, or nothing happening at all) means it was not.
Process.flag(:trap_exit, true)
{:ok, _supervisor, _pipeline} = Membrane.Pipeline.start_link(Repro, fragment)

receive do
  {:EXIT, _pid, reason} ->
    if inspect(reason) =~ ":killed" do
      IO.puts("FAILED: demuxer killed by the heap cap - it expanded the declared sample_count")
      System.halt(1)
    else
      IO.puts("PASSED: fragment rejected without allocating (#{inspect(reason, limit: 2)})")
    end
after
  10_000 -> IO.puts("PASSED: pipeline still alive, nothing was expanded")
end
