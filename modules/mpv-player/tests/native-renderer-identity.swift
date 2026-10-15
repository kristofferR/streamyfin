import Foundation
import MPVKit

// The identity policy, node/event decoders and progress/pause receipt methods
// are production code. Only UIKit/mpv ownership and delivery are replaced here.
enum DispatchQueue {
    static let main = DeliveryQueue()
}
final class DeliveryQueue {
    var pending: [() -> Void] = []
    func async(execute work: @escaping () -> Void) { pending.append(work) }
    func drain() {
        while !pending.isEmpty { pending.removeFirst()() }
    }
}
final class RendererDelegate {
    var pauses: [Bool] = []
    var generations: [UInt] = []
    var progress: [Double] = []
    var durations: [Double] = []
    func renderer(_ renderer: MPVLayerRenderer, didChangePause paused: Bool, loadGeneration: UInt) {
        pauses.append(paused)
        generations.append(loadGeneration)
    }
    func renderer(_ renderer: MPVLayerRenderer, didUpdatePosition position: Double,
                  duration: Double, cacheSeconds: Double, loadGeneration: UInt) {
        progress.append(position)
        durations.append(duration)
    }
}
final class MPVLayerRenderer {
    var fileIdentity = MPVFileIdentity()
    var cachedPosition = 120.0
    var cachedDuration = 0.0
    var cachedCacheSeconds = 0.0
    var isPaused = true
    var delegate: RendererDelegate? = RendererDelegate()
}

@main
struct RendererIdentityTests {
    static func commandResult(_ status: Int32, _ id: Int64,
                              key: String = "playlist_entry_id",
                              format: mpv_format = MPV_FORMAT_INT64) -> Int64? {
        var value = mpv_node()
        value.format = format
        value.u.int64 = id
        var keyBytes = Array(key.utf8CString)
        return keyBytes.withUnsafeMutableBufferPointer { bytes in
            var keys: [UnsafeMutablePointer<CChar>?] = [bytes.baseAddress]
            var values = [value]
            return keys.withUnsafeMutableBufferPointer { keys in
                values.withUnsafeMutableBufferPointer { values in
                    var list = mpv_node_list()
                    list.num = 1
                    list.keys = keys.baseAddress
                    list.values = values.baseAddress
                    return withUnsafeMutablePointer(to: &list) { pointer in
                        var result = mpv_node()
                        result.format = MPV_FORMAT_NODE_MAP
                        result.u.list = pointer
                        return MPVLayerRenderer.playlistEntryID(from: result, status: status)
                    }
                }
            }
        }
    }

    static func main() {
        let renderer = MPVLayerRenderer()
        let handle = MPVFileIdentity.Handle()
        let largeID = Int64(1) << 40
        precondition(commandResult(0, largeID) == largeID, "all entry-ID bits survive the real C node parser")
        precondition(commandResult(-1, largeID) == nil, "failed command cannot bind an otherwise valid node")
        precondition(commandResult(0, -1) == nil && commandResult(0, 1, key: "other") == nil)
        precondition(commandResult(0, 1, format: MPV_FORMAT_NONE) == nil)
        precondition(MPVLayerRenderer.playlistEntryID(from: mpv_node(), status: 0) == nil)

        renderer.fileIdentity.begin(handle: handle, generation: 1)
        renderer.fileIdentity.bind(handle: handle, generation: 1, entryID: commandResult(0, 11))
        renderer.fileIdentity.begin(handle: handle, generation: 2)
        renderer.fileIdentity.bind(handle: handle, generation: 2, entryID: commandResult(0, 12))
        // Request 1 never starts. The sole surviving START belongs to request 2.
        renderer.fileIdentity.start(handle: handle, entryID: 12)
        let surviving = renderer.captureProgress(named: "duration", value: 1800)!
        precondition(surviving.identity.loadGeneration == 2 && surviving.position == 120)

        // Same URL reload: native entry identity, not URL equality, controls cache writes.
        renderer.fileIdentity.begin(handle: handle, generation: 3)
        precondition(renderer.captureProgress(named: "time-pos", value: 900) == nil)
        precondition(renderer.cachedPosition == 120, "outgoing receipts cannot pollute the new resume seed")
        renderer.fileIdentity.start(handle: handle, entryID: 13)
        precondition(renderer.captureProgress(named: "time-pos", value: 0) == nil,
                     "a START/property preceding result binding cannot borrow the requested generation")
        renderer.fileIdentity.bind(handle: handle, generation: 3, entryID: commandResult(0, 13))
        let current = renderer.captureProgress(named: "time-pos", value: 121)!
        precondition(current.identity.loadGeneration == 3 && current.identity.entryID == 13)
        precondition(surviving.identity.loadGeneration == 2 && surviving.position == 120,
                     "later mutable cache updates cannot relabel or change a captured receipt")

        renderer.fileIdentity.start(handle: handle, entryID: 99)
        renderer.fileIdentity.start(handle: handle, entryID: 88)
        precondition(renderer.captureProgress(named: "duration", value: 999) == nil)
        renderer.fileIdentity.start(handle: handle, entryID: 13)
        renderer.fileIdentity.end(handle: handle, entryID: 12)
        precondition(renderer.fileIdentity.receipt?.entryID == 13, "unrelated END cannot clear another file")
        renderer.fileIdentity.end(handle: handle, entryID: 13)
        precondition(renderer.captureProgress(named: "time-pos", value: 999) == nil)

        renderer.fileIdentity.begin(handle: handle, generation: 4)
        renderer.fileIdentity.start(handle: handle, entryID: 14)
        renderer.fileIdentity.bind(handle: handle, generation: 4, entryID: commandResult(-1, 14))
        precondition(renderer.captureProgress(named: "duration", value: 0) == nil)
        precondition(renderer.cachedDuration == 1800, "rejection cannot mutate an accepted cache")

        renderer.fileIdentity.clear() // stop/shutdown/queue overflow
        let newHandle = MPVFileIdentity.Handle()
        renderer.fileIdentity.begin(handle: newHandle, generation: 5)
        renderer.fileIdentity.bind(handle: newHandle, generation: 5, entryID: commandResult(0, 13))
        renderer.fileIdentity.start(handle: handle, entryID: 13)
        precondition(renderer.captureProgress(named: "time-pos", value: 999) == nil,
                     "a reused numeric ID from an old handle is not the new file")
        renderer.fileIdentity.start(handle: newHandle, entryID: 13)
        var nativeValue = 122.0
        withUnsafeMutablePointer(to: &nativeValue) { pointer in
            var property = mpv_event_property()
            property.format = MPV_FORMAT_DOUBLE
            property.data = UnsafeMutableRawPointer(pointer)
            let value = MPVLayerRenderer.eventDouble(property)!
            let receipt = renderer.captureProgress(named: "time-pos", value: value)!
            pointer.pointee = 999
            precondition(receipt.position == 122 && receipt.identity.handle === newHandle,
                         "real event payload data is copied before mpv can reuse its storage")
            property.format = MPV_FORMAT_NONE
            precondition(MPVLayerRenderer.eventDouble(property) == nil)
        }
        renderer.fileIdentity.clear()
        renderer.fileIdentity.bind(handle: newHandle, generation: 5, entryID: 13)
        renderer.fileIdentity.start(handle: newHandle, entryID: 13)
        precondition(renderer.captureProgress(named: "time-pos", value: 999) == nil,
                     "a late result/start cannot resurrect an invalidated request")
        let pauseRenderer = MPVLayerRenderer()
        let pauseHandle = MPVFileIdentity.Handle()
        pauseRenderer.fileIdentity.begin(handle: pauseHandle, generation: 10)
        pauseRenderer.fileIdentity.bind(handle: pauseHandle, generation: 10, entryID: 41)
        pauseRenderer.fileIdentity.start(handle: pauseHandle, entryID: 41)
        pauseRenderer.reportPause(true)
        DispatchQueue.main.drain()
        precondition(pauseRenderer.delegate!.pauses.isEmpty && pauseRenderer.delegate!.progress.isEmpty,
                     "an unchanged paused state neither duplicates a notification nor invents progress")
        // FILE_LOADED reconciliation then a queued equal pause property.
        pauseRenderer.reportPause(false)
        pauseRenderer.reportPause(false)
        DispatchQueue.main.drain()
        precondition(!pauseRenderer.isPaused && pauseRenderer.delegate!.pauses == [false],
                     "cached true/native false reports the change once; the equal event cannot swallow it")
        precondition(pauseRenderer.delegate!.generations == [10] && pauseRenderer.delegate!.progress.isEmpty,
                     "reconciliation carries file generation and never fabricates progress")

        pauseRenderer.reportPause(true)
        pauseRenderer.reportPause(true, position: 999)
        DispatchQueue.main.drain()
        precondition(pauseRenderer.isPaused && pauseRenderer.delegate!.pauses == [false, true],
                     "cached false/native true reports once, including when the next event is equal")
        precondition(pauseRenderer.delegate!.progress.isEmpty,
                     "the paused FILE_LOADED path does not report a made-up physical clock")

        pauseRenderer.reportPause(false)
        pauseRenderer.cachedDuration = 240
        pauseRenderer.reportPause(true, position: 133)
        pauseRenderer.cachedDuration = 999
        DispatchQueue.main.drain()
        precondition(pauseRenderer.delegate!.progress == [133] && pauseRenderer.delegate!.durations == [240],
                     "a genuine pause preserves the validated physical-clock snapshot")
        pauseRenderer.fileIdentity.clear()
        pauseRenderer.reportPause(false, position: 900)
        DispatchQueue.main.drain()
        precondition(pauseRenderer.isPaused && pauseRenderer.delegate!.pauses == [false, true, false, true],
                     "an unowned pause cannot change the cache or notify a new session")
        print("Renderer native identity, C decoding and progress/pause receipts passed")
    }
}
