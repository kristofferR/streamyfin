# Streamyfin source binding proposal

This is the fork-owned source binding based on libmpv-android 1.0.0 at
`fcf6745703dc1265bca88f12fee8fc355ddf251e`, initially prepared as
`f6a4adba403fdd4e431349f882481f2bb41ccc84` and vendored in Streamyfin's
review candidate. No replacement AAR is released. Compiler, JNI/runtime and
consumer validation remain unrun for the current changes.

The local END payload addition, unsupported-playlist behavior and baseline EOF limits are documented in
[END_FILE-evidence.md](END_FILE-evidence.md). Legacy callbacks are preserved;
media cores, runtime-byte verification and pinned headers are unchanged.
The following sections retain the source-consumption design and its validation
requirements; implementation is not proof that those requirements have passed.

## Consumption without a new binary release

Vendor `LICENSE`, `libmpv/proguard-rules.pro`, `libmpv/src/main`, `libmpv/src/test` and `consumer` into
`modules/mpv-player/android/libmpv-binding`. Preserve the base commit and
`PROVENANCE.json`, and verify the tracked `source-inputs.sha256` before building.
Do not copy this repository's root build, publishing plugin or workflow.

An Expo settings plugin would persist `settings.gradle.snippet` through prebuild.
A root Gradle plugin addition would apply `substitution.gradle` so every normal
consumer of `dev.jdtech.mpv:libmpv` selects the source project. These app changes
are proposed only. No submodule, mutable branch dependency, `mavenLocal`, new
Maven repository, or new released AAR is needed for this source route.

`consumer/build.gradle` uses the app's Android plugin and Expo Kotlin helper,
root SDK/Kotlin settings and Java 17. It does not apply the dependency's original
AGP 9.1/Java 21/publishing build. It pins the existing NDK 29.0.14206865 and CMake
4.1.2 for the JNI rebuild. Compatibility still needs the proposed cloud compile.

The existing released AAR is a non-transitive raw input, checksum-verified before
extraction. Both root custom substitution and global composite substitution
bypass `releasedMediaCore`. Resolution occurs in the preparation task, never
through eager configuration-time artifact access. The old `classes.jar` and
`libplayer.so` are not dependencies or extracted runtime inputs.

Only Kotlin and `libplayer.so` are rebuilt. CMake imports released `libmpv.so`
and `libavcodec.so` outside `jniLibs`; other released native libraries go into
`jniLibs` once. NDK supplies `libc++_shared.so`. Verification requires the packaged
runtime and every media core to remain byte-identical to the released AAR; a
runtime mismatch stops validation instead of silently changing it. There are
no `pickFirst` rules hiding duplicate libraries.

If this source-build route is declined, an immutable, reviewed replacement AAR
would be a separate release blocker. This preparation does not authorize one.

## API and event ordering

Existing `command`, `EventObserver`, and logging APIs are retained. Additions:

* `loadFile(url): LoadResult`, using `mpv_command_ret` with `loadfile … replace`.
  It returns mpv's status and the exact returned 64-bit entry identity. Missing
  or rejected results have no identity; no later playlist-property read fills it.
* `PlaybackSource` is an opaque token created once per player. `FileIdentity`
  combines that token with the entry ID, so IDs reused by another handle cannot
  match. Same-URL reloads get distinct entry IDs.
* `addIdentifiedObserver` and `removeIdentifiedObserver`, with typed optional
  `IdentifiedEventObserver` callbacks. JNI entrypoints preserve the event
  thread's entry ID alongside each primitive property value or discrete event.
  Legacy observers continue receiving their original callbacks.

The native event loop uses actual START_FILE payload IDs, clears the active ID
on its matching END_FILE, shutdown or queue overflow, and never counts requests.
An unrelated end cannot clear a newer active ID. Properties with no known file
carry null. All new callback iteration uses a snapshot without holding a lock.

This receipt-stamping contract is specific to the pinned mpv 0.41 source:

1. [command.c](https://github.com/mpv-player/mpv/blob/v0.41.0/player/command.c)
   marks all observed properties dirty for START_FILE and END_FILE.
2. [client.c `send_event`](https://github.com/mpv-player/mpv/blob/v0.41.0/player/client.c)
   invalidates cached property timestamps under the client lock before queuing
   the transition event.
3. `mpv_wait_event` drains discrete queued events before generating property
   notifications. Its hook exception deliberately drains old property changes
   before a hook; these retain the preceding event identity.
4. `gen_property_change_event` emits a value only when its value timestamp matches
   its change timestamp. Coalescing does not turn a pre-transition cached value
   into a fresh property after the queued transition.

No one-to-one load/start relationship is assumed. A command can finish before or
after its start callback, and intermediate requests can be cancelled or rejected.
The future host must invalidate its request before JNI, bind only the command's
exact returned identity, snapshot values at receipt, and re-check request and
file identity before any main-thread mutation. Early progress callbacks before
binding can be dropped. Lifecycle events such as FILE_LOADED must instead be
delivered after binding on the host's serialized owner, or retained with their
exact file identity until command completion; dropping them could lose readiness
forever. JNI/commands must run outside that policy lock. This host integration
is still to be reviewed and implemented; native receipt stamping alone is not a
completed fix for the Android finding.

## Validation draft and current limits

`validation.draft.yml` is outside `.github/workflows` and cannot run. It describes
an Ubuntu 26.04/Java 17 job checking an exact future Streamyfin commit, frozen Bun
inputs, SDK 36/build-tools 35.0.0/NDK 29.0.14206865/CMake 4.1.2 and actual Gradle
module tasks before compilation. The Apple archive job must depend on its success.
No APK, signing, media, device, publishing, artifact-upload or comment tasks run.

The tests cover 64-bit results, rejection/missing result, a cancelled request
without START_FILE, several starts before command completion, immutable IDs,
matching/unrelated ends, overflow/shutdown, distinct handles and same-URL reloads.
Cloud assembly must additionally prove Kotlin/JNI descriptor agreement, all four
ABI architectures, retained legacy JNI exports/linking, unique class/native archive entries, byte-identical media
cores/runtime, and runtime graph selection of only the source binding. The draft
host module compile/tests become meaningful once the separately reviewed host
guard is integrated. No local compile or test has run; real JNI execution is not
proven by these static/host checks.

## Licensing

The binding remains under its existing MIT `LICENSE`. The vendored mpv client
header carries its original ISC notice; FFmpeg's JNI header carries its original
LGPL-2.1-or-later notice and license text. Retain those notices and provenance.

The reused media binaries retain their own licensing and corresponding-source
obligations. They are not MIT merely because the wrapper is MIT. The pinned
[mpv copyright file](https://github.com/mpv-player/mpv/blob/v0.41.0/Copyright)
describes GPL as the default build and LGPL as an optional build mode; the
binding build script does not request the LGPL mode. Existing media-license
handling must be carried forward before any distribution. No binary publication
or legal compatibility conclusion is part of this preparation.
