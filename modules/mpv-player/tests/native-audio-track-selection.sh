#!/bin/bash
set -euo pipefail

tests_dir="$(cd "$(dirname "$0")" && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

# Compile the actual selection method against a small mpv/queue test double.
ruby - "$tests_dir/../ios/MPVLayerRenderer.swift" "$test_dir/Selection.swift" <<'RUBY'
source = File.read(ARGV[0])
method = source[/^    func setAudioTrack\(_ trackId: Int\) \{.*?(?=^    func getCurrentAudioTrack)/m]
startup = source[/^    func start\(\) throws \{.*?(?=^        \/\/ Logging\.)/m]
abort 'audio selection or startup method not found' unless method && startup
File.write(ARGV[1], "extension AudioTrackSelectionHarness {\n#{method}\n#{startup}\n    }\n}\n")
RUBY
swiftc "$test_dir/Selection.swift" "$tests_dir/native-audio-track-selection.swift" -o "$test_dir/test"
"$test_dir/test"
