defmodule Membrane.MP4.Demuxer.CMAF.SamplesInfo do
  @moduledoc false

  alias Membrane.MP4.MovieBox.SampleTableBox

  @type sample_description :: %{
          duration: non_neg_integer(),
          ts: non_neg_integer(),
          size: non_neg_integer(),
          composition_offset: non_neg_integer(),
          offset: non_neg_integer(),
          track_id: non_neg_integer()
        }

  # A compact run of identical samples (see `handle_trun/4`), sorted among plain
  # `sample_description`s by its first `offset`.
  @type sample_run :: %{
          offset: non_neg_integer(),
          ts: non_neg_integer(),
          count: non_neg_integer(),
          size: pos_integer(),
          duration: non_neg_integer(),
          composition_offset: non_neg_integer(),
          track_id: non_neg_integer()
        }

  @spec read_moov(moov_box :: map()) ::
          {%{non_neg_integer() => struct()}, %{non_neg_integer() => pos_integer()}}
  def read_moov(%{children: boxes}) do
    tracks =
      boxes
      |> Enum.filter(fn {type, _content} -> type == :trak end)
      |> Enum.into(%{}, fn {:trak, %{children: boxes}} ->
        {boxes[:tkhd].fields.track_id, boxes}
      end)

    tracks_info =
      Map.new(tracks, fn {track_id, boxes} ->
        sample_table =
          SampleTableBox.unpack(
            boxes[:mdia].children[:minf].children[:stbl],
            boxes[:mdia].children[:mdhd].fields.timescale
          )

        {track_id, sample_table.sample_description}
      end)

    timescales =
      Map.new(tracks, fn {track_id, boxes} ->
        {track_id, boxes[:mdia].children[:mdhd].fields.timescale}
      end)

    {tracks_info, timescales}
  end

  @spec get_samples_info(moof_box :: map()) :: [sample_description() | sample_run()]
  def get_samples_info(%{children: boxes}) do
    boxes
    |> Enum.filter(fn {type, _content} -> type == :traf end)
    |> Enum.map(fn {:traf, box} -> box end)
    |> Enum.flat_map(&handle_traf/1)
    |> Enum.sort_by(& &1.offset)
  end

  defp handle_traf(traf_box) do
    track_description = %{
      track_id: traf_box.children[:tfhd].fields.track_id,
      base_data_offset: traf_box.children[:tfhd].fields[:base_data_offset] || 0,
      default_sample_duration: traf_box.children[:tfhd].fields[:default_sample_duration] || 0,
      default_sample_size: traf_box.children[:tfhd].fields[:default_sample_size],
      base_media_decode_time: traf_box.children[:tfdt].fields.base_media_decode_time || 0
    }

    {samples, _acc} =
      traf_box.children
      |> Enum.filter(fn {box_name, _box} -> box_name == :trun end)
      |> Enum.flat_map_reduce(
        {track_description.base_data_offset, track_description.base_media_decode_time},
        fn {:trun, trun_box}, {offset_acc, ts_acc} ->
          handle_trun(trun_box, offset_acc, ts_acc, track_description)
        end
      )

    samples
  end

  # ISO/IEC 14496-12 8.8.8: without the data-offset-present flag a run starts at
  # `base_data_offset` (first run of the traf) or right after the previous run's data - both are
  # `offset_acc`.
  defp base_offset(fields, offset_acc, track_description) do
    case fields[:data_offset] do
      nil -> offset_acc
      data_offset -> track_description.base_data_offset + data_offset
    end
  end

  # `ParseHelper` stops materializing a counted list whose items carry no bits, so a `trun` with
  # every per-sample field gated off parses to `samples: []` with the declared count left in
  # `sample_count`. All its samples are identical, so they are kept as one compact run descriptor
  # that `Engine.read_mdat/2` expands against the `mdat` that has to back it - the declared count
  # never drives an allocation on its own. Note that only `tfhd` defaults are read here, not
  # `mvex`/`trex` ones.
  defp handle_trun(%{fields: %{samples: []} = fields}, offset_acc, ts_acc, track_description) do
    count = fields.sample_count
    offset = base_offset(fields, offset_acc, track_description)
    size = track_description.default_sample_size
    duration = track_description.default_sample_duration

    cond do
      count == 0 ->
        {[], {offset, ts_acc}}

      # Without a positive size every sample would sit at the same offset, so no amount of `mdat`
      # bytes could bound the run - reject instead of letting `count` drive the expansion.
      is_nil(size) or size <= 0 ->
        raise "Malformed trun: #{count} samples declared with sample size #{inspect(size)}"

      true ->
        run = %{
          offset: offset,
          ts: ts_acc,
          count: count,
          size: size,
          duration: duration,
          composition_offset: 0,
          track_id: track_description.track_id
        }

        {[run], {offset + count * size, ts_acc + count * duration}}
    end
  end

  defp handle_trun(trun_box, offset_acc, ts_acc, track_description) do
    Enum.map_reduce(
      trun_box.fields.samples,
      {base_offset(trun_box.fields, offset_acc, track_description), ts_acc},
      fn sample, {size_acc, ts_acc} ->
        size = sample[:sample_size] || track_description.default_sample_size
        duration = sample[:sample_duration] || track_description.default_sample_duration

        {%{
           duration: duration,
           ts: ts_acc,
           size: size,
           composition_offset: sample[:sample_composition_time_offset] || 0,
           offset: size_acc,
           track_id: track_description.track_id
         }, {size_acc + size, ts_acc + duration}}
      end
    )
  end
end
