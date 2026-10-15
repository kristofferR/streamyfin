import Foundation

let MPV_FORMAT_INT64: Int32 = 4

final class Logger {
    static let shared = Logger()
    func log(_ message: String, type: String) {}
}

// The runner compiles the production setAudioTrack method in this harness.
// Only the mpv property access and delivery queue are replaced.
final class AudioTrackSelectionHarness {
    var mpv: Int? = 1
    var currentId: Int64 = 1
    var readStatus: Int32 = 0
    var passthrough = ["truehd"] // DTS-HD was refused on the active track.
    var writes: [String] = []
    var pending: [() -> Void] = []

    func onQueue(_ work: @escaping () -> Void) { pending.append(work) }
    func drain() {
        while !pending.isEmpty { pending.removeFirst()() }
    }
    func getProperty(handle: Int, name: String, format: Int32, value: inout Int64) -> Int32 {
        value = currentId
        return readStatus
    }
    func restoreSpatialAudioPassthrough() { passthrough = ["truehd", "dts-hd"] }
    func setProperty(name: String, value: String) {
        writes.append(value)
        currentId = Int64(value)!
    }
}

@main
struct AudioTrackSelectionTests {
    static func main() {
        let same = AudioTrackSelectionHarness()
        same.setAudioTrack(1)
        same.drain()
        precondition(same.passthrough == ["truehd"] && same.writes.isEmpty,
                     "same-track selection must preserve PCM fallback without restarting audio")

        let changed = AudioTrackSelectionHarness()
        changed.setAudioTrack(2)
        precondition(changed.writes.isEmpty, "track selection waits for the player's queue")
        changed.drain()
        precondition(changed.passthrough == ["truehd", "dts-hd"] && changed.writes == ["2"],
                     "another track gets a fresh spatial attempt")

        let queued = AudioTrackSelectionHarness()
        queued.setAudioTrack(2)
        queued.setAudioTrack(2)
        queued.drain()
        precondition(queued.writes == ["2"], "read the active track on the queue after earlier selections")

        let unreadable = AudioTrackSelectionHarness()
        unreadable.readStatus = -1
        unreadable.setAudioTrack(2)
        unreadable.drain()
        precondition(unreadable.passthrough == ["truehd"] && unreadable.writes == ["2"],
                     "unknown current track preserves refusal while honoring the requested selection")

        let stopped = AudioTrackSelectionHarness()
        stopped.setAudioTrack(2)
        stopped.mpv = nil
        stopped.drain()
        precondition(stopped.writes.isEmpty && stopped.passthrough == ["truehd"],
                     "a queued selection cannot touch a stopped player")
        print("Native audio track selection: 5 checks passed")
    }
}
