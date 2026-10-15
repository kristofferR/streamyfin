import { isSameStreamUrl } from "./syncPlay";

/** The slice of the native session the engine's onLoad writes. */
export type LoadEventSession = {
  stream: { url: string };
  awaitingLoad: boolean;
  isMuted: boolean;
  isPlaying: boolean;
  hasPlaybackStarted: boolean;
};

export type LoadEvent = { url?: string; muted?: boolean; isPlaying?: boolean };

/**
 * Applies onLoad only when it names this session's stream. A legacy event
 * without a URL keeps the existing behavior rather than leaving playback gated.
 *
 * Mute and the play state ride along because both otherwise reach JS only as
 * transitions. A stream swapped in while the player plays never pauses or
 * resumes, so without the play state the new session would never count as
 * started and would send no progress report at all, seeks and track changes
 * included.
 */
export function applyLoadEvent(
  session: LoadEventSession,
  event: LoadEvent,
): boolean {
  if (event.url && !isSameStreamUrl(event.url, session.stream.url)) return false;
  session.awaitingLoad = false;
  if (typeof event.muted === "boolean") session.isMuted = event.muted;
  if (typeof event.isPlaying === "boolean") {
    session.isPlaying = event.isPlaying;
    if (event.isPlaying) session.hasPlaybackStarted = true;
  }
  return true;
}
