# Pinned Apple command and file identity API

The app's existing MPVKit 0.41.0-av5 dependency is unchanged. Its tag is
`09331943dddcd51f75f70cdca535a7bc29be4fcf`; its build script selects mpv v0.41.0.

Inspected released input:

- URL: https://github.com/streamyfin/MPVKit/releases/download/0.41.0-av5/MPVKit.xcframework.zip
- Size: 256938980 bytes
- GitHub-reported asset digest: `sha256:80a79fbb34b1a3ae84744fe7bb9d365d2a006a5f617460933b7ce777251d3618`
- iOS arm64 and tvOS device `Headers/mpv/client.h` were read directly from ZIP
  ranges, inflated and checked against each entry's CRC. Both are byte-identical.
- Header SHA256: `3c073236a09cb456c6e80587d5523c8771c32fb22ca014e0f99cc3d43905b75c`
- The simulator header entries have the same size and CRC in the ZIP directory.
  Their contents were not separately extracted.

The shipped public header declares API 2.5, `mpv_command_ret`,
`mpv_free_node_contents`, `mpv_event_start_file.playlist_entry_id` and the matching
END_FILE ID. The renderer reads only the command's returned node-map entry and
actual event payload, never a later playlist/path property or request FIFO.

`mpv_command_ret` runs synchronously on the existing mpv queue, outside host
locks. START/property events can be generated while it runs, but the same serial
queue cannot consume them before the result is bound. The policy also handles a
START before binding without assigning a generation to early properties.

The same header hash is already present in the immutable Android source snapshot.
The cloud renderer harness imports that real C header, compiles the production
node/payload decoders and receipt/cache method, and exercises the production
identity policy. Full unsigned archives must still prove the actual pinned
Apple framework imports and links these APIs. No native framework binary was
executed, no local compilation/tests ran, and the full asset digest was not
independently recomputed from a complete download. This is header/source evidence,
not compiler/runtime validation.
