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

The source project replaces binding classes/JNI only. Its checksum-verified
released AAR supplies media cores. Cloud validation must prove every core and
the C++ runtime remains byte-identical and all four ABI/JNI contracts agree.
See `modules/mpv-player/android/libmpv-binding/consumer/README.md` for provenance
and licensing. Native runtime execution is not established by compile checks.
