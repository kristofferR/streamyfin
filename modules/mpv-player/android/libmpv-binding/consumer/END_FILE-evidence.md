# Pinned END_FILE and redirect contract

Source audit only. Tests, JNI execution and consumer/archive validation remain
unrun for this candidate. The released media input and headers are unchanged.

All mpv links below pin `41f6a645068483470267271e1d09966ca3b9f413`
(`v0.41.0`), the version selected by the binding build and inspected core.

- [common/playlist.c, transfer implementation](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/common/playlist.c#L302)
  assigns each transferred entry the next destination `id_alloc` in one loop,
  without callbacks or intervening insertions, then returns the first entry ID.
  Its following function comment explicitly specifies contiguous IDs. Checked
  `first + count - 1` therefore describes membership for this pinned payload.
- [player/loadfile.c, transfer_playlist](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/player/loadfile.c#L973)
  prepares the playlist before transferring it. Shuffle/resume may select an
  entry other than the first; rebinding directly to `playlist_insert_id` is wrong.
  The actual subsequent START supplies the selected physical entry ID.
- [player/loadfile.c, playback lifecycle](https://github.com/mpv-player/mpv/blob/41f6a645068483470267271e1d09966ca3b9f413/player/loadfile.c#L1533)
  stamps START and END with the same physical entry. Transfer copies the inserted
  ID/count into END. Failed opening/decoding can emit ERROR without FILE_LOADED;
  command success only establishes the allocated entry, not readiness.

JNI copies ended entry, reason, error, inserted first ID and count before the
next wait invalidates payload storage. Legacy event callbacks remain intact.
The optional identified END callback defaults to the previous identified event.

Host policy binds the exact command-result root and same playback source. Only
an accepted parent's REDIRECT extends bounded lineage. Actual START must match
the root or a proven, non-retired descendant. Ranges must advance beyond known
allocated IDs, have positive count and pass checked signed-64-bit arithmetic.
Malformed data, early-event overflow or lineage exhaustion fails explicitly.
No URL, current playlist property, request FIFO or guessed first child is used.
EOF may continue to another proven child; ERROR/STOP/QUIT terminate the request.
EOF/error delivery also rejects replacement, shutdown and retired physical files.
EOF preserves already captured physical progress before its terminal report.
