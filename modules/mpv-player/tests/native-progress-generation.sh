#!/bin/bash
set -euo pipefail

tests_dir="$(cd "$(dirname "$0")" && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

ruby - "$tests_dir/../ios/PlayerEngine.swift" "$test_dir/Progress.swift" <<'RUBY'
source = File.read(ARGV[0])
method = source[/^\tfunc renderer\(_: MPVLayerRenderer, didUpdatePosition.*?(?=^\tfunc renderer\(_: MPVLayerRenderer, didChangePause)/m]
abort 'engine progress callback not found' unless method
File.write(ARGV[1], "extension MPVPlayerEngine {\n#{method}}\n")
RUBY
swiftc "$test_dir/Progress.swift" "$tests_dir/native-progress-generation.swift" -o "$test_dir/test"
"$test_dir/test"
