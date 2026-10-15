# Android mpv load identity

`MPVLayerRenderer` consumes only identified callbacks from the vendored
libmpv-android source binding. `loadfile` request order does not identify
START_FILE events: a request can be replaced before it starts. Bind the exact
command-result entry ID and the per-player source token instead.

`MpvLoadPolicy` stamps request ownership at receipt, retains bounded early
lifecycle events, and guards main-owner cache/delegate mutations. JNI and
callbacks run outside its lock. Overflow fails the load explicitly. Stop and
shutdown invalidate outstanding receipts; never add legacy observers alongside
this path.

Ordinary `END_FILE(EOF)` retains accepted `FILE_LOADED` preparation until its
initial track work and `onLoad` finish. Recheck ownership after `onLoad`, which
can replace the item. ERROR, REDIRECT, STOP and QUIT cancel pending success.
Keep the `eof-reached` true/false latch for held frames and per-file replay;
this supplies baseline EOF semantics, not rapid-seek or coalesced-cycle proof.

Pause clock, duration and cache snapshots run on the existing serial native
worker, outside policy locks. Retain original request/file identity and pause
revision through final delivery; a later native pause observation revokes an
older report. Check native pause state around the reads and ownership before
progress and again before pause. `FILE_LOADED` reconciliation uses the same
worker and revision fence. This adds no per-command pause/seek acknowledgement.
The focused asynchronous preparation and pause tests remain unrun until cloud
validation succeeds; native/JNI code and media cores are unchanged here.

The source project replaces binding classes/JNI only. Its checksum-verified
released AAR supplies media cores. Cloud validation must prove every core and
the C++ runtime remains byte-identical and all four ABI/JNI contracts agree.
See `modules/mpv-player/android/libmpv-binding/consumer/README.md` for provenance
and licensing. Native runtime execution is not established by compile checks.
