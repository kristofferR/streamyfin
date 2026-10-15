# Project-owned dependency verification

[Run 38807335965](https://github.com/kristofferR/streamyfin/actions/runs/38807335965)
on source a1ce748f passed native CTest, all four binding ABI builds, binding/host
Kotlin compilation and unit tasks, the unchanged strict AAR verifier, and the
supplemental C++ symbol/version checker. All 32 media cores and four released
runtimes matched. This is binding evidence, not app runtime or playback proof.

It then failed because the binding task resolved the host's debug runtime
configuration without its owning project lock. Gradle 9.3.1
[requires that lock](https://github.com/gradle/gradle/blob/v9.3.1/platforms/software/dependency-management/src/main/java/org/gradle/api/internal/artifacts/configurations/DefaultConfiguration.java#L543).

The existing binding verification task now depends on project-owned assertions
in both `:mpv-player` and `:app`. Each resolves only its own runtime graph and
requires exactly one source binding and no released binding. There is no eager
configuration-time resolution, lock bypass, artifact extraction or native task
dependency added by these assertions. The raw released-media bypass is unchanged.

This correction needs fresh required review and exact-candidate cloud validation.
The preceding successful native checks do not mark the corrected candidate tested.
Actual app merge/runtime-provider checks and all four Apple archives were skipped.
