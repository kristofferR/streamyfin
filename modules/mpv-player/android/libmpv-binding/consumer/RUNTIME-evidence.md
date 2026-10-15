# Released C++ runtime proposal and validation boundary

This is a static local proposal after diagnostic run
[38757274840](https://github.com/kristofferR/streamyfin/actions/runs/38757274840).
No new candidate compilation, native execution, final app merge or cloud run has
validated this recipe. RN/Expo packaging policies are unchanged.

## Three separate claims

1. **Binding link and AAR runtime:** `ANDROID_STL=none` suppresses automatic NDK
   STL linking/packaging. CMake restores only the pinned NDK 29 libc++ headers and
   links an imported target pointing to the checksum-verified released runtime.
   AGP packages that imported library outside `jniLibs`, just like the existing
   imported mpv/avcodec inputs. `--no-undefined` remains enabled. This recipe has
   not compiled; unavailable symbols must fail, not trigger a runtime substitution.
2. **Immutable AAR inputs:** the unchanged strict `verify-aar.sh` still requires
   every core and runtime byte to match the released AAR. Diagnostic evidence
   proves all 32 copied cores match. The previous candidate instead packaged a
   different `libc++_shared.so` on all four ABIs. Rebuilt `libplayer.so` is the
   only intentionally different native library. Strip/debug flags are unchanged.
3. **Final app runtime and compatibility:** the binding AAR does not determine
   the host's selected runtime. The pinned RN plugin builds the app with
   `c++_shared`, adds its existing runtime `pickFirst`, and gives the app-native
   runtime precedence. The expected app winner is therefore the NDK runtime for
   both the original published dependency and this source proposal, for the three
   configured app ABIs. This is source-grounded expectation, not an observed merge.
   New `libplayer` imports must also be checked against the actual app-selected
   runtime, alongside the existing native modules. This remains a blocker.

## Released ELF evidence

Input AAR SHA256:
`df146592480fc8418415a06b1f1a1d6318b0088e21f52254b0e9a82b61ca8fa2`.
Read-only inspection used an already installed LLVM readelf; no compiler or SDK
installation was run. Complete text metadata and dynamic-symbol tables are kept
outside the repository in `Streamyfin-validation-evidence/runtime-static-audit`.

| ABI | Released runtime bytes | GNU build ID |
| --- | ---: | --- |
| arm64-v8a | 1374336 | ba615e4ff75bc2d8ba1eee93f983e02bc427c433 |
| armeabi-v7a | 963028 | 4dcbebec34af5743a8ca1c37483a5c82c8f665e4 |
| x86 | 1255932 | 31f820ad49515e490ef8d3fb596f4c81bef5e0b3 |
| x86_64 | 1337488 | 3013104c45517f8ad33d82df55191b7cec21204d |

All four have SONAME `libc++_shared.so`, NEEDED entries `libc.so`, `libm.so`
and `libdl.so`, and version requirements named `LIBC` from libc/libdl. Their C++
exports are unversioned; no C++ version definitions were found. They have no
`.debug_*` or `.symtab` sections. Comments identify Clang/LLD 21.0.0
(`5e96669f06077099aa41290cdb4c5e6fa0f59349`), plus Clang 19 input metadata.
Android ident records API 21, r28/build 13004108. That embedded runtime-build
label is not proof that the containing NDK package was r28.

The pinned original binding recipe at
[`fcf6745703dc1265bca88f12fee8fc355ddf251e`](https://github.com/jarnedemeulemeester/libmpv-android/tree/fcf6745703dc1265bca88f12fee8fc355ddf251e)
specifies NDK `29.0.14206865`, `c++_shared`, C++11 and a published release variant.
Our previous AAR used a debug build with `keepDebugSymbols` for all native files.
This supports a stripping/debug-packaging explanation for the large size delta;
it does not prove one. The discarded candidate ELF sections/build IDs/exports
were not retained, so neither stripping-only equivalence nor an ABI/version
incompatibility can be concluded from the size/hash difference.

Each original released `libplayer` has three C++ dynamic imports, all provided
by its released runtime: allocation, deletion and `std::__ndk1::__call_once`.
This only checks the old binary. The rebuilt binary's requirements remain
unproven. The proposed supplemental `verify-runtime-link.rb` checks all four
rebuilt bindings' strong C++ dynamic symbols and symbol versions against their
AAR runtime, and reports optional unresolved weak symbols. It does not replace
the strict verifier or establish playback compatibility.

## Exact runtime/header route

The pinned NDK r29 source at
[`196e0661200bad5361340700fea67be12e1f1684`](https://android.googlesource.com/platform/ndk/+/196e0661200bad5361340700fea67be12e1f1684/build/cmake/android-legacy.toolchain.cmake)
adds `-nostdinc++` and `-nostdlib++` for `ANDROID_STL=none` (lines 376-378).
The [build-system guide](https://android.googlesource.com/platform/ndk/+/196e0661200bad5361340700fea67be12e1f1684/docs/BuildSystemMaintainers.md)
documents libc++ headers in the toolchain sysroot's `usr/include/c++/v1`.
Only that header directory is restored via the imported runtime target. Clang
still supplies its compiler support/unwinder; neither compiler nor NDK changes.
The imported runtime is extracted once under `releasedMedia/cmake/<ABI>` and
excluded from `jniLibs` to avoid duplicate packaging. No `pickFirst`, overwrite,
alternate runtime, strip or debug-option workaround is added.

Existing MIT/ISC/FFmpeg notices remain. The libc++ license is copied verbatim
from the runtime's pinned LLVM source and included by the existing notices task.
Binary distribution and licensing conclusions remain outside this preparation.

After a separately approved cloud build, run the original verifier first, then:

```sh
ruby "$binding/consumer/verify-runtime-link.rb" "$candidate_aar" "$pinned_readelf"
```

## Baseline versus source substitution in the same host

The original published-dependency candidate is
[`77ec6e62f4ec25332ec7ee89802f53a1a22af871`](https://github.com/kristofferR/streamyfin/commit/77ec6e62f4ec25332ec7ee89802f53a1a22af871).
Between it and source candidate `9f25cbbbb`, `package.json`, `bun.lock`,
`plugins/withGradleProperties.ts` and the mpv module's `build.gradle` are identical.
The only `app.json` delta is enabling the source-substitution plugin. Host RN,
Expo, NDK, architecture selection and native packaging policies are the same.
Baseline consumes the published AAR through the mpv project; substitution supplies
the source project's JNI inputs instead. Both compete with the app-native runtime.

Installed pinned sources show:

* RN Gradle plugin 0.86.0, `NdkConfiguratorUtils.kt:51-52`: app CMake defaults to
  `c++_shared`; lines 78-89 add existing `**/libc++_shared.so` pickFirst and state
  app-native precedence. The source project is a library, so its `none` setting
  does not override that app policy.
* AGP 8.12.0 `MergeNativeLibsTask`: project inputs are visited before subproject
  and external inputs (lines 160-162); pickFirst copies the first path only
  (lines 214-217). Inputs include app external-native-build outputs, project JNI
  artifacts, and external runtime-classpath JNI artifacts (lines 454-515).
  AGP 8.12.0 is the pinned RN plugin's dependency; resolved build-tool identity
  must also be logged when a comparison is authorized.
* Expo modules core 57.0.20 links `c++_shared` but excludes its intermediate shared
  libraries from normal library packaging; its test-only pickFirst branch is
  not the application policy.
* `app.json` configures arm64-v8a, x86_64 and armeabi-v7a. x86 is a binding ABI,
  not a configured app-native ABI. No app-wide x86 compatibility claim follows.

For the three configured host ABIs the proposal is expected to preserve the
baseline app-NDK winner, not introduce it. Exact selected bytes/build IDs and
new binding plus other-module compatibility are still unknown. An AAR-only
pass cannot clear that boundary.

## Proposed smallest conclusive cloud comparison, not added or authorized

Use two exact checkouts (the original candidate above and the reviewed successor),
the identical frozen host/toolchain setup and unchanged RN/Expo policies. Serial
execution may reuse downloads; do not assume cross-candidate compiled-output reuse.
First capture resolved AGP/NDK/CMake identities and the generated app ABIs. The
binding pins CMake 4.1.2; the app has no explicit CMake version, so that selection
must be reviewed rather than assumed to inherit the binding's setting.

For each checkout propose:

1. Inventory `:app:mergeDebugNativeLibs --dry-run` and its actual producer graph
   before executing it. The registered AGP task name is source-confirmed, but
   the complete configured task graph has not run. Stop if it introduces APK,
   signing, upload/publication, device or unexpected test tasks. Keep Sentry
   auto-upload disabled and confirm no upload finalizers can execute.
2. Run only `:app:mergeDebugNativeLibs`, then read its `MERGED_NATIVE_LIBS` output
   before stripping/packaging. Record every runtime candidate's provider and
   SHA256, the selected runtime hash/build ID/SONAME, selected `libplayer` hash,
   effective ABI set and unchanged packaging options. Require source/merged
   byte correspondence. Compare baseline/proposal winner and explain any delta.
3. Audit the actual selected runtime against the rebuilt binding and each
   merged existing module's required C++ symbol/version set for every configured
   host ABI. Keep the separate four-ABI binding/AAR gate. Missing strong symbols,
   unexplained selection changes or unresolved version requirements block progress;
   weak imports and limitations must be reported, not turned into runtime proof.

This is smaller than APK assembly but is not a cheap copy task. AGP obtains
`MERGED_JNI_LIBS`, app `EXTERNAL_NATIVE_BUILD_LIBS`, and project/external runtime
JNI artifacts. Therefore it can trigger `mergeDebugJniLibFolders`, app CMake
configuration/native builds, Prefab extraction, autolinking/codegen, source
binding native builds and other JNI-producing library builds. RN's default
`ReactNative-application.cmake` adds appmodules plus autolinked/codegen targets.
Those app-native producers were not built by the existing module compile gate.
Java/Kotlin/JS task requirements depend on those actual producers; no hand-listed
subset or `-x` bypass is proposed. No signing/APK/release target is requested.

Cost is unmeasured: existing focused module compilation took 2m46s, with a
separate 3m08s Gradle task/configuration step in the diagnostic run. A first app
native graph across three ABIs can add substantial compilation for each of two
checkouts. Exact task dependencies, wall time and SDK/CMake needs cannot be
truthfully asserted from the retained module-only log. Review the graph and
budget before granting that work; do not silently enlarge the current 60-minute
Android job or claim that the existing gate covers it. No workflow change or
dispatch for this comparison is included in the local source proposal.
