import { applyLoadEvent, type LoadEventSession } from "./applyLoadEvent";
import { applyProgressTick } from "./applyProgressTick";

// A session as beginSession creates it, waiting for its stream.
const fresh = (): LoadEventSession & {
  positionMs: number;
  lastProgressReportAt: number;
} => ({
  stream: { url: "https://jellyfin.test/Videos/new/stream?AudioStreamIndex=2" },
  awaitingLoad: true,
  isMuted: false,
  isPlaying: false,
  hasPlaybackStarted: false,
  positionMs: 0,
  lastProgressReportAt: 0,
});

describe("applyLoadEvent", () => {
  test("an outgoing load cannot start the new session or open its progress gate", () => {
    const s = fresh();
    const before = { ...s };
    expect(
      applyLoadEvent(s, {
        url: "https://jellyfin.test/Videos/old/stream?AudioStreamIndex=2",
        muted: true,
        isPlaying: true,
      }),
    ).toBe(false);
    expect(s).toEqual(before);
    // This is the provider's progress gate while the new item is loading.
    expect(
      !s.awaitingLoad &&
        applyProgressTick(s, { position: 2400 }, 1_000, 10_000),
    ).toBe(false);
    expect(s.positionMs).toBe(0);

    expect(applyLoadEvent(s, { url: s.stream.url, isPlaying: true })).toBe(true);
    expect(
      applyProgressTick(s, { position: 30 }, 11_000, 10_000),
    ).toBe(true);
    expect(s.positionMs).toBe(30_000);
  });

  test("a renegotiated stream rejects the previous audio selection's load", () => {
    const s = fresh();
    expect(
      applyLoadEvent(s, {
        url: s.stream.url.replace("AudioStreamIndex=2", "AudioStreamIndex=1"),
        isPlaying: true,
      }),
    ).toBe(false);
    expect(s.awaitingLoad).toBe(true);
  });

  test("accepts Foundation's percent encoding of the requested stream", () => {
    const s = fresh();
    s.stream.url = "file:///media/A movie.mkv";
    expect(
      applyLoadEvent(s, { url: "file:///media/A%20movie.mkv", isPlaying: true }),
    ).toBe(true);
    expect(s.awaitingLoad).toBe(false);
  });

  test("an event without a usable URL keeps the legacy load behavior", () => {
    const s = fresh();
    expect(applyLoadEvent(s, { url: "", isPlaying: true })).toBe(true);
    expect(s.hasPlaybackStarted).toBe(true);
  });

  test("a stream swapped in while the player plays reports its progress", () => {
    // No pause or resume happens across the swap, so onLoad is the only
    // place the new session learns it is playing.
    const s = fresh();
    applyLoadEvent(s, { muted: false, isPlaying: true });
    expect(s).toMatchObject({
      awaitingLoad: false,
      isPlaying: true,
      hasPlaybackStarted: true,
    });
    expect(
      applyProgressTick(s, { position: 2400, didSeek: true }, 1_000, 10_000),
    ).toBe(true);
  });

  test("a stream loaded paused has not started", () => {
    const s = fresh();
    applyLoadEvent(s, { isPlaying: false });
    expect(s.isPlaying).toBe(false);
    expect(s.hasPlaybackStarted).toBe(false);
  });

  test("leaves the play state alone when the engine does not send it", () => {
    const s = fresh();
    applyLoadEvent(s, { muted: true });
    expect(s).toMatchObject({
      awaitingLoad: false,
      isMuted: true,
      isPlaying: false,
      hasPlaybackStarted: false,
    });
  });
});
