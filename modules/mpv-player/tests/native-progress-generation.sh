#!/bin/bash
set -euo pipefail

tests_dir="$(cd "$(dirname "$0")" && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

ruby - "$tests_dir/../ios/PlayerEngine.swift" "$test_dir/Progress.swift" <<'RUBY'
source = File.read(ARGV[0])
method = source[/^\tfunc renderer\(_: MPVLayerRenderer, didUpdatePosition.*?(?=^\tfunc renderer\(_: MPVLayerRenderer, didChangeLoading)/m]
abort 'engine progress callback not found' unless method
shutdown = source[/^\tfunc shutdown\(\).*?(?=^\tdeinit)/m]
abort 'engine shutdown not found' unless shutdown
File.write(ARGV[1], "import Foundation\nextension MPVPlayerEngine {\n#{method}\n#{shutdown}}\n")
RUBY
swiftc "$test_dir/Progress.swift" "$tests_dir/native-progress-generation.swift" -o "$test_dir/test"
"$test_dir/test"

# Exercise actual renderer identity assignment, C result/payload decoding and
# cache mutation, using the exact pinned client header without executing mpv.
header_path="$tests_dir/../android/libmpv-binding/consumer/headers/mpv/client.h"
mkdir -p "$test_dir/MPVKit"
cat > "$test_dir/MPVKit/module.modulemap" <<MODULE
module MPVKit [system] {
    header "$header_path"
    export *
}
MODULE

ruby - "$tests_dir/../ios/MPVLayerRenderer.swift" "$test_dir/RendererReceipts.swift" <<'RUBY'
source = File.read(ARGV[0])
methods = ['private static func playlistEntryID', 'private static func eventDouble', 'private func captureProgress', 'private func capturePause', 'private func reportPause', 'private func handleQueueOverflow'].map do |name|
  start = source.index(name) or abort "missing production method: #{name}"
  finish = source.index('{', start) or abort 'missing method body'
  depth = 1
  while depth > 0
    finish += 1
    abort 'unterminated production method' if finish >= source.length
    depth += 1 if source[finish] == '{'
    depth -= 1 if source[finish] == '}'
  end
  source[start..finish].sub('private ', '')
end
File.write(ARGV[1], "import Foundation\nimport MPVKit\nextension MPVLayerRenderer {\n#{methods.join("\n")}\n}\n")
RUBY

swiftc -I "$test_dir/MPVKit" "$tests_dir/../ios/MPVFileIdentity.swift" \
    "$test_dir/RendererReceipts.swift" "$tests_dir/native-renderer-identity.swift" -o "$test_dir/renderer-test"
"$test_dir/renderer-test"
