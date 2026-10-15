# Pinned END_FILE and single-file playback contract

Source audit only. Tests, JNI/runtime execution, Android consumer compilation and
all four Apple archives remain unrun. Media cores, runtime-byte gates and pinned
headers are unchanged.

JNI freezes the ended entry, reason, error and inserted ID/count before the next
wait invalidates payload storage. Legacy callbacks remain intact; the optional
identified END callback defaults to the previous identified event. The host binds
only the exact command-result entry and native source, not a request FIFO or URL.

## Unsupported playlist input

An accepted `MPV_END_FILE_REASON_REDIRECT` fails once through the existing owned
error route: "Playlist inputs are not supported by this player". Child readiness,
progress, success and EOF cannot complete that request. Only a still-owned input
is stopped, outside policy locks and on the same serial owner as replacement.
HTTP redirection and URL suffixes are not rejection criteria.

The player models one Jellyfin item, URL, progress clock and track selection.
There is no mpv multi-file timeline/advancement contract. No redirect ranges,
lineage mode, playlist advancement commands or completion snapshots remain.

The pinned [loadfile lifecycle](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/player/loadfile.c#L2000)
emits END before choosing a following playlist entry. Child EOF cannot establish
whole-playlist completion. Both supported host load paths use `stop` then
`loadfile ... replace`, which clears the old playlist. With actual playlist
REDIRECT rejected, iOS can report accepted exact-root EOF directly; it keeps
historical immediate Engine `didLoad`. STOP/QUIT and ERROR remain distinct.

## Android baseline EOF, held frame and limits

The [published baseline](https://github.com/kristofferR/streamyfin/commit/285a2127bdba8a7991e2908c4b5a057390be2ab8)
observes Boolean `eof-reached`: true reports once, false resets the completion
latch. `keep-open=always` and per-file `loop-file=inf/no` are retained. Pinned
[keep-open handling](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/player/playloop.c#L983)
holds the last frame, so normal EOF need not emit END. Removing the observer in
an intermediate local candidate was a new regression; restoring it is required.

The restored latch lives with the exact request/source/entry policy. An already
received false invalidates queued older true receipts; replacement, shutdown,
ERROR and REDIRECT revoke stale delivery. Early EOF waits for initial track
preparation and `onLoad`, so it cannot overtake that acknowledgement. Ordinary
held EOF leaves the prepared file usable for replay. No stop is issued for it.
Native SEEK/RESTART alone neither report EOF nor rearm its latch.

These are baseline semantics, not applied-seek correlation. Public property
notifications can coalesce true/false/true, and the public seek result acknowledges
queueing rather than the actual applied seek. This patch does not establish a
newest-seek acknowledgement, guaranteed replay-cycle counts under coalescing,
or seek-to-EOF/rapid-seek completion guarantees. Those existing limitations need
separate protocol work; no observation-epoch JNI/API, timers, private core access
or media-core changes are introduced here. They are not compiler/runtime proof.

Focused production-policy/Engine/renderer tests cover ordinary EOF deduplication,
false reset, early acknowledgement ordering, native loop/seek events, queued
receipt revocation, error and redirect rejection. Redirected child EOF is delivered
before a later child START and must not reach host completion. These tests are
unrun until the approved cloud validation succeeds.
