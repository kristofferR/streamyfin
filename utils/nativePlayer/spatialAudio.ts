import type { Api } from "@jellyfin/sdk";
import {
  AudioSpatialFormat,
  type MediaSourceInfo,
  type MediaStream,
} from "@jellyfin/sdk/lib/generated-client";
import type { NativePlayerSpatialAudio } from "@/modules/mpv-player";

/**
 * The tracks SpatialAudioBridge plays as Apple spatial audio (APAC): TrueHD
 * with Atmos and DTS:X. Jellyfin reads both from the FFmpeg profile; mpv
 * decodes them to PCM and loses the objects.
 */
export const isSpatialAudioStream = (stream: MediaStream | undefined) => {
  const codec = stream?.Codec?.toLowerCase();
  return (
    (codec === "truehd" &&
      stream?.AudioSpatialFormat === AudioSpatialFormat.DolbyAtmos) ||
    (codec === "dts" && stream?.AudioSpatialFormat === AudioSpatialFormat.Dtsx)
  );
};

/** Video Jellyfin can copy into fMP4 segments that AVPlayer plays. */
const COPYABLE_VIDEO_CODECS = new Set(["hevc", "h264"]);

/**
 * Audio cheap for the server to transcode. The master playlist must carry
 * audio, which AVPlayer then ignores for the APAC, so Jellyfin should not
 * spend a TrueHD decode on it.
 */
const LIGHT_AUDIO_CODECS = new Set(["aac", "ac3", "eac3", "mp3", "opus"]);

/** Text subtitles in Jellyfin's order, the order of its HLS renditions. */
const textSubtitles = (mediaSource: MediaSourceInfo) =>
  (mediaSource.MediaStreams ?? []).filter(
    (s) => s.Type === "Subtitle" && s.IsTextSubtitleStream,
  );

/**
 * How the native player plays the selected audio track as spatial audio, or
 * undefined when it plays through mpv: anything but online direct play of a
 * Matroska file whose track is TrueHD Atmos or DTS:X, with video Jellyfin can
 * copy and no subtitle that would have to be burned in.
 */
export const resolveSpatialAudio = (options: {
  /** The setting is on and the native tvOS 26 player plays the item. */
  enabled: boolean;
  api: Pick<Api, "basePath" | "accessToken" | "deviceInfo">;
  itemId: string;
  mediaSource: MediaSourceInfo;
  audioIndex: number | undefined;
  subtitleIndex: number;
  playSessionId: string;
  /**
   * AVPlayer loads the video and subtitles itself and cannot attach custom
   * proxy headers to those requests.
   */
  needsHeaders: boolean;
}): NativePlayerSpatialAudio | undefined => {
  const { api, mediaSource } = options;
  if (
    !options.enabled ||
    options.needsHeaders ||
    !mediaSource.Id ||
    mediaSource.TranscodingUrl ||
    mediaSource.IsRemote ||
    !mediaSource.Container?.split(",").includes("mkv")
  ) {
    return undefined;
  }

  const streams = mediaSource.MediaStreams ?? [];
  const video = streams.find((s) => s.Type === "Video");
  if (!COPYABLE_VIDEO_CODECS.has(video?.Codec?.toLowerCase() ?? "")) {
    return undefined;
  }

  const audioIndex = options.audioIndex ?? mediaSource.DefaultAudioStreamIndex;
  const fileAudio = streams
    .filter((s) => s.Type === "Audio" && !s.IsExternal)
    .sort((a, b) => (a.Index ?? 0) - (b.Index ?? 0));
  const audioTrackOrdinal = fileAudio.findIndex((s) => s.Index === audioIndex);
  if (!isSpatialAudioStream(fileAudio[audioTrackOrdinal])) return undefined;

  if (
    options.subtitleIndex !== -1 &&
    !textSubtitles(mediaSource).some((s) => s.Index === options.subtitleIndex)
  ) {
    return undefined;
  }

  const lightAudio = fileAudio.find((s) =>
    LIGHT_AUDIO_CODECS.has(s.Codec?.toLowerCase() ?? ""),
  );
  // Stream copy keeps 4K HDR untouched, and AVPlayer needs fMP4 for HEVC.
  // Text subtitles come along as WebVTT renditions, which the stream keeps.
  const params = new URLSearchParams({
    MediaSourceId: mediaSource.Id,
    DeviceId: api.deviceInfo.id,
    PlaySessionId: options.playSessionId,
    VideoCodec: "hevc,h264",
    AllowVideoStreamCopy: "true",
    SegmentContainer: "mp4",
    BreakOnNonKeyFrames: "true",
    AudioCodec: "aac",
    AudioStreamIndex: String(lightAudio?.Index ?? audioIndex),
    TranscodingMaxAudioChannels: "2",
    AudioBitrate: "128000",
    AllowAudioStreamCopy: "false",
    SubtitleMethod: "Hls",
    ApiKey: api.accessToken,
  });
  return {
    videoMasterUrl: `${api.basePath}/Videos/${options.itemId}/master.m3u8?${params}`,
    audioTrackOrdinal,
  };
};

/**
 * The 1-based subtitle rendition that shows `jellyfinIndex` while spatial
 * audio plays, or undefined for none. Jellyfin lists a rendition for every
 * text subtitle, in stream order.
 */
export const spatialSubtitleTrack = (
  mediaSource: MediaSourceInfo,
  jellyfinIndex: number,
): number | undefined => {
  const position = textSubtitles(mediaSource).findIndex(
    (s) => s.Index === jellyfinIndex,
  );
  return position === -1 ? undefined : position + 1;
};

/**
 * How a subtitle pick applies around spatial audio: as one of the stream's
 * renditions, by re-negotiating the stream, or (undefined) in mpv as usual.
 * An image subtitle has to be drawn by mpv, and leaving the one that kept a
 * spatial audio track on mpv lets the track play as spatial audio again.
 */
export const spatialSubtitleChange = (options: {
  mediaSource: MediaSourceInfo;
  /** The stream plays as spatial audio now. */
  playing: boolean;
  /** The current audio track would play as spatial audio. */
  preferred: boolean;
  from: number;
  to: number;
}): "rendition" | "reload" | undefined => {
  const isImage = (index: number) =>
    (options.mediaSource.MediaStreams ?? []).some(
      (s) =>
        s.Type === "Subtitle" &&
        s.Index === index &&
        s.IsTextSubtitleStream === false,
    );
  if (options.playing) return isImage(options.to) ? "reload" : "rendition";
  if (options.preferred && isImage(options.from) && !isImage(options.to)) {
    return "reload";
  }
  return undefined;
};
