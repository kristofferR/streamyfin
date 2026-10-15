# Android native worker and pending readiness

Static source evidence, not runtime proof. The new focused Kotlin tests and
current source must pass cloud compilation and validation before being reported
as tested. No binding/JNI interface, media core, dependency or seek protocol changes.

Each handle has a serial native worker. Retirement invalidates receipts and drops
queued work, then runs the existing stop/detach path independently of a blocked
subtitle fetch. Ownership is released by teardown, not by a timeout. A replacement
handle has its own worker; retired work cannot write to it. Work remaining within
one live handle stays serialized, including initial subtitle preparation and load
replacement. Network/native calls are not promised a completion deadline.

Pinned mpv's [sub-add definition](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/player/command.c#L7261)
uses a worker and enables cancellation on playback end. Its
[external-file open](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/player/loadfile.c#L858)
releases the core lock while opening the URL. Playback teardown
[aborts coupled commands](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/player/loadfile.c#L1953).
The binding's synchronous command waits for command completion; queuing stop
behind the fetch prevented that cancellation path from running.

Internal recovery keeps a pending host acknowledgement while allocating a new
exact request identity. Only accepted FILE_LOADED plus completed subtitle/track
preparation can acknowledge it, once. Terminal, stopped or different-handle
requests do not transfer success.

FILE_LOADED metadata, chapters and PLAYBACK_RESTART clock reads run on the handle's worker,
with ownership checked around native reads and final main delivery. Later native
metadata properties win over an outstanding one-shot read. Observed SEEK/RESTART
revokes an older queued restart clock; this is not a newest-host-seek acknowledgement
and does not alter the documented baseline rapid-seek/EOF limitations.
Queued restart delivery also preserves a newer delivered native position and
metadata observations rather than overwriting them with an older worker reply.
