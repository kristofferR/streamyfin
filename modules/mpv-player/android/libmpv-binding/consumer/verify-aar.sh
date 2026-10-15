#!/bin/bash
set -euo pipefail

released="$1"
rebuilt="$2"
readelf="$3"
binding_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

test "$(sha256sum "$released" | cut -d ' ' -f 1)" = df146592480fc8418415a06b1f1a1d6318b0088e21f52254b0e9a82b61ca8fa2
test -z "$(unzip -Z1 "$rebuilt" | sort | uniq -d)"
unzip -Z1 "$released" | rg '^jni/[^/]+/[^/]+\.so$' | sort > "$temporary/released-native"
unzip -Z1 "$rebuilt" | rg '^jni/[^/]+/[^/]+\.so$' | sort > "$temporary/rebuilt-native"
cmp "$temporary/released-native" "$temporary/rebuilt-native"

# All media cores and the C++ shared runtime must remain byte-for-byte identical.
while IFS= read -r member; do
    case "$member" in */libplayer.so) continue ;; esac
    unzip -p "$released" "$member" > "$temporary/old.so"
    unzip -p "$rebuilt" "$member" > "$temporary/new.so"
    cmp "$temporary/old.so" "$temporary/new.so"
done < "$temporary/released-native"

for abi in arm64-v8a armeabi-v7a x86 x86_64; do
    unzip -p "$rebuilt" "jni/$abi/libplayer.so" > "$temporary/player.so"
    unzip -p "$released" "jni/$abi/libplayer.so" > "$temporary/old-player.so"
    # Preserve the actual released ELF architecture and every legacy JNI export.
    "$readelf" --file-header "$temporary/old-player.so" | rg 'Class:|Machine:' > "$temporary/old-architecture"
    "$readelf" --file-header "$temporary/player.so" | rg 'Class:|Machine:' > "$temporary/new-architecture"
    cmp "$temporary/old-architecture" "$temporary/new-architecture"
    "$readelf" --dyn-syms "$temporary/old-player.so" | awk '$5 == "GLOBAL" && $7 != "UND" && $8 ~ /^Java_/ {print $8}' | sort -u > "$temporary/old-exports"
    "$readelf" --dyn-syms "$temporary/player.so" | awk '$5 == "GLOBAL" && $7 != "UND" && $8 ~ /^Java_/ {print $8}' | sort -u > "$temporary/new-exports"
    test -z "$(comm -23 "$temporary/old-exports" "$temporary/new-exports")"
    rg -x 'Java_dev_jdtech_mpv_MPVLib_nativeLoadFile' "$temporary/new-exports"
    "$readelf" --dynamic "$temporary/player.so" | rg 'Shared library: \[libmpv.so\]'
    unzip -p "$released" "jni/$abi/libmpv.so" > "$temporary/mpv.so"
    "$readelf" --dyn-syms "$temporary/mpv.so" | awk '$5 == "GLOBAL" && $7 != "UND" && $8 == "mpv_command_ret" {found=1} END {exit !found}'
done

unzip -p "$rebuilt" classes.jar > "$temporary/classes.jar"
jar tf "$temporary/classes.jar" > "$temporary/classes"
test -z "$(sort "$temporary/classes" | uniq -d)"
test "$(rg -cx 'dev/jdtech/mpv/MPVLib.class' "$temporary/classes")" = 1
test "$(rg -cx 'dev/jdtech/mpv/FileIdentity.class' "$temporary/classes")" = 1
javap -p -s -classpath "$temporary/classes.jar" dev.jdtech.mpv.MPVLib > "$temporary/jni-methods"
ruby - "$binding_root/libmpv/src/main/cpp/jni_utils.cpp" "$temporary/jni-methods" <<'RUBY'
native = File.read(ARGV[0]).scan(/GetMethodID\(mpv_MPVLib, "([^"]+)", "([^"]+)"\)/)
bytecode = File.read(ARGV[1]).scan(/\b(identifiedEventProperty|identifiedEvent|identifiedEndFile|logMessage)\([^)]*\);\n\s+descriptor: ([^\n]+)/)
abort 'no JNI callback lookups found' if native.empty?
native.each do |signature|
  abort "JNI callback descriptor missing: #{signature.join(' ')}" unless bytecode.include?(signature)
end
RUBY
echo 'AAR ABI, immutable core/runtime bytes, unique class/native entries, JNI exports and callback descriptors verified'
