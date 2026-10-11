import type {
  MediaSourceInfo,
  MediaStream,
} from "@jellyfin/sdk/lib/generated-client";
import {
  isSpatialAudioStream,
  resolveSpatialAudio,
  spatialSubtitleChange,
  spatialSubtitleTrack,
} from "./spatialAudio";

const atmos: MediaStream = {
  Type: "Audio",
  Index: 2,
  Codec: "truehd",
  AudioSpatialFormat: "DolbyAtmos",
};
const ac3: MediaStream = { Type: "Audio", Index: 3, Codec: "ac3" };
const srt: MediaStream = {
  Type: "Subtitle",
  Index: 4,
  Codec: "subrip",
  IsTextSubtitleStream: true,
};
const pgs: MediaStream = {
  Type: "Subtitle",
  Index: 5,
  Codec: "PGSSUB",
  IsTextSubtitleStream: false,
};
const ass: MediaStream = {
  Type: "Subtitle",
  Index: 6,
  Codec: "ass",
  IsTextSubtitleStream: true,
};

const source = (overrides: Partial<MediaSourceInfo> = {}): MediaSourceInfo => ({
  Id: "src",
  Container: "mkv",
  MediaStreams: [
    { Type: "Video", Index: 0, Codec: "hevc" },
    { Type: "Audio", Index: 1, Codec: "dts" },
    atmos,
    ac3,
    srt,
    pgs,
    ass,
  ],
  ...overrides,
});

const resolve = (
  overrides: Partial<Parameters<typeof resolveSpatialAudio>[0]> = {},
) =>
  resolveSpatialAudio({
    enabled: true,
    api: {
      basePath: "http://jellyfin:8096",
      accessToken: "token",
      deviceInfo: { id: "device", name: "Apple TV" },
    },
    itemId: "item",
    mediaSource: source(),
    audioIndex: 2,
    subtitleIndex: -1,
    playSessionId: "session",
    needsHeaders: false,
    ...overrides,
  });

describe("isSpatialAudioStream", () => {
  it("accepts TrueHD Atmos and DTS:X", () => {
    expect(isSpatialAudioStream(atmos)).toBe(true);
    expect(
      isSpatialAudioStream({ Codec: "dts", AudioSpatialFormat: "DTSX" }),
    ).toBe(true);
  });

  it("rejects plain TrueHD, DTS-HD MA and Dolby Digital Plus Atmos", () => {
    expect(isSpatialAudioStream({ Codec: "truehd" })).toBe(false);
    expect(
      isSpatialAudioStream({ Codec: "dts", AudioSpatialFormat: "None" }),
    ).toBe(false);
    expect(
      isSpatialAudioStream({ Codec: "eac3", AudioSpatialFormat: "DolbyAtmos" }),
    ).toBe(false);
  });
});

describe("resolveSpatialAudio", () => {
  it("addresses the track by its place among the file's audio tracks", () => {
    // Jellyfin numbers every stream; the Matroska reader only counts audio.
    expect(resolve()?.audioTrackOrdinal).toBe(1);
  });

  it("asks Jellyfin for stream-copy video with light audio and text subtitles", () => {
    const url = new URL(resolve()?.videoMasterUrl ?? "");
    expect(url.pathname).toBe("/Videos/item/master.m3u8");
    expect(Object.fromEntries(url.searchParams)).toMatchObject({
      MediaSourceId: "src",
      PlaySessionId: "session",
      AllowVideoStreamCopy: "true",
      SegmentContainer: "mp4",
      AudioCodec: "aac",
      AudioStreamIndex: "3",
      SubtitleMethod: "Hls",
      // Jellyfin 12 refuses the older api_key.
      ApiKey: "token",
    });
  });

  it("falls back to the server's default track", () => {
    expect(
      resolve({
        audioIndex: undefined,
        mediaSource: source({ DefaultAudioStreamIndex: 2 }),
      }),
    ).toBeDefined();
  });

  it("leaves text and image subtitles to mpv to keep captions in sync", () => {
    expect(resolve({ subtitleIndex: 4 })).toBeUndefined();
    expect(resolve({ subtitleIndex: 5 })).toBeUndefined();
    expect(resolve({ subtitleIndex: 6 })).toBeUndefined();
  });

  it("uses another non-spatial track when no light audio track exists", () => {
    const mediaSource = source({
      MediaStreams: source().MediaStreams?.filter((s) => s.Index !== 3),
    });
    const url = new URL(resolve({ mediaSource })?.videoMasterUrl ?? "");
    expect(url.searchParams.get("AudioStreamIndex")).toBe("1");
  });

  it("still plays files whose only audio track is spatial", () => {
    const mediaSource = source({
      MediaStreams: [{ Type: "Video", Index: 0, Codec: "hevc" }, atmos],
    });
    const url = new URL(resolve({ mediaSource })?.videoMasterUrl ?? "");
    expect(url.searchParams.get("AudioStreamIndex")).toBe("2");
  });

  it("leaves everything else to mpv", () => {
    expect(resolve({ enabled: false })).toBeUndefined();
    expect(resolve({ needsHeaders: true })).toBeUndefined();
    expect(resolve({ audioIndex: 1 })).toBeUndefined();
    expect(
      resolve({ mediaSource: source({ TranscodingUrl: "/master.m3u8" }) }),
    ).toBeUndefined();
    expect(resolve({ mediaSource: source({ Container: "mp4" }) })).toBe(
      undefined,
    );
    expect(
      resolve({
        mediaSource: source({
          MediaStreams: [{ Type: "Video", Index: 0, Codec: "av1" }, atmos],
        }),
      }),
    ).toBeUndefined();
  });
});

describe("spatialSubtitleTrack", () => {
  it("counts only the text subtitles, which are the renditions", () => {
    expect(spatialSubtitleTrack(source(), 4)).toBe(1);
    expect(spatialSubtitleTrack(source(), 6)).toBe(2);
    expect(spatialSubtitleTrack(source(), -1)).toBeUndefined();
  });
});

describe("spatialSubtitleChange", () => {
  const change = (
    overrides: Partial<Parameters<typeof spatialSubtitleChange>[0]>,
  ) =>
    spatialSubtitleChange({
      mediaSource: source(),
      playing: false,
      preferred: false,
      from: -1,
      to: -1,
      ...overrides,
    });

  it("reloads through mpv when enabling text subtitles", () => {
    expect(change({ playing: true, from: -1, to: 4 })).toBe("reload");
    expect(change({ playing: true, from: -1, to: 6 })).toBe("reload");
    expect(change({ playing: true, from: -1, to: -1 })).toBe("rendition");
  });

  it("hands an image subtitle to mpv", () => {
    expect(change({ playing: true, from: 4, to: 5 })).toBe("reload");
  });

  it("returns to spatial audio when disabling any subtitle", () => {
    expect(change({ preferred: true, from: 4, to: -1 })).toBe("reload");
    expect(change({ preferred: true, from: 5, to: -1 })).toBe("reload");
  });

  it("leaves other picks to mpv", () => {
    expect(change({ preferred: true, from: 4, to: 6 })).toBeUndefined();
    expect(change({ preferred: true, from: 5, to: 4 })).toBeUndefined();
    expect(change({ preferred: false, from: 5, to: 4 })).toBeUndefined();
  });
});
