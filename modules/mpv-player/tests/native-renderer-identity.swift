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
    var errors: [String] = []
    var errorGenerations: [UInt] = []
    var ends = 0
    func rendererDidReachEnd(_ renderer: MPVLayerRenderer, identity: MPVFileIdentity.Receipt) { ends += 1 }
    var pauses: [Bool] = []
    var generations: [UInt] = []
    var progress: [Double] = []
    var durations: [Double] = []
    func renderer(_ renderer: MPVLayerRenderer, didFailWithError message: String, loadGeneration: UInt) {
        errors.append(message)
        errorGenerations.append(loadGeneration)
    }
    func renderer(_ renderer: MPVLayerRenderer, didChangePause paused: Bool, identity: MPVFileIdentity.Delivery) {
        pauses.append(paused)
        generations.append(identity.loadGeneration)
    }
    func renderer(_ renderer: MPVLayerRenderer, didUpdatePosition position: Double,
                  duration: Double, cacheSeconds: Double, identity: MPVFileIdentity.Delivery) {
        progress.append(position)
        durations.append(duration)
    }
}
final class MPVLayerRenderer {
    var fileIdentity = MPVFileIdentity()
    let queue = DeliveryQueue()
    var mpv: OpaquePointer? = OpaquePointer(bitPattern: 1)
    var identityHandle: OpaquePointer? = OpaquePointer(bitPattern: 1)
    var identitySource = MPVFileIdentity.Handle()
    var commands: [[String]] = []
    func commandSync(_ handle: OpaquePointer, _ arguments: [String]) { commands.append(arguments) }

    var cachedPosition = 120.0
    var loadStartPosition = 120.0
    var lastProgressUpdateTime = 0.0
    var cachedDuration = 0.0
    var cachedCacheSeconds = 0.0
    var isPaused = true
    var isReadyToSeek = true
    var isSeeking = true
    var isLoading = true
    var delegate: RendererDelegate? = RendererDelegate()
}

@main
struct RendererIdentityTests {
    static func end(_ entry: Int64, _ reason: Int, _ first: Int64 = 0, _ count: Int = 0) -> MPVEndFile {
        MPVEndFile(entryID: entry, reason: reason, error: -13, insertID: first, insertCount: count)
    }
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
        let overflowRenderer = MPVLayerRenderer()
        overflowRenderer.fileIdentity.begin(handle: handle, generation: 11)
        // No START_FILE or command result yet: the request still owns failure.
        overflowRenderer.handleQueueOverflow(source: handle)
        precondition(!overflowRenderer.isReadyToSeek && !overflowRenderer.isSeeking && !overflowRenderer.isLoading)
        overflowRenderer.fileIdentity.bind(handle: handle, generation: 11, entryID: 22)
        overflowRenderer.fileIdentity.start(handle: handle, entryID: 22)
        precondition(overflowRenderer.captureProgress(named: "time-pos", value: 900) == nil,
                     "late native events cannot resurrect identity after overflow")
        overflowRenderer.handleQueueOverflow(source: handle)
        DispatchQueue.main.drain()
        precondition(overflowRenderer.delegate!.errorGenerations == [11],
                     "pre-START overflow reports one explicit error for the owning generation")

        overflowRenderer.fileIdentity.begin(handle: handle, generation: 12)
        overflowRenderer.fileIdentity.bind(handle: handle, generation: 12, entryID: 23)
        overflowRenderer.fileIdentity.start(handle: handle, entryID: 23)
        overflowRenderer.handleQueueOverflow(source: MPVFileIdentity.Handle())
        precondition(overflowRenderer.captureProgress(named: "time-pos", value: 130) != nil,
                     "an old handle's overflow cannot invalidate the new file")
        overflowRenderer.handleQueueOverflow(source: handle)
        precondition(overflowRenderer.captureProgress(named: "time-pos", value: 900) == nil)
        DispatchQueue.main.drain()
        precondition(overflowRenderer.delegate!.errorGenerations == [11, 12])
        overflowRenderer.fileIdentity.begin(handle: handle, generation: 13)
        overflowRenderer.fileIdentity.bind(handle: handle, generation: 13, entryID: 24)
        overflowRenderer.fileIdentity.start(handle: handle, entryID: 24)
        precondition(overflowRenderer.captureProgress(named: "time-pos", value: 140)?.identity.loadGeneration == 13,
                     "an explicit new load can report after terminal overflow")
        overflowRenderer.fileIdentity.clear() // Shutdown before a late overflow.
        overflowRenderer.handleQueueOverflow(source: handle)
        DispatchQueue.main.drain()
        precondition(overflowRenderer.delegate!.errorGenerations == [11, 12])
        var nativeEnd = mpv_event_end_file()
        nativeEnd.playlist_entry_id = largeID
        nativeEnd.reason = MPV_END_FILE_REASON_REDIRECT
        nativeEnd.error = -13
        nativeEnd.playlist_insert_id = largeID + 1
        nativeEnd.playlist_insert_num_entries = 3
        withUnsafeMutablePointer(to: &nativeEnd) { pointer in
            var event = mpv_event()
            event.data = UnsafeMutableRawPointer(pointer)
            let snapshot = MPVLayerRenderer.endFileSnapshot(event)!
            pointer.pointee.playlist_insert_id = 0
            precondition(snapshot.entryID == largeID && snapshot.reason == 5 && snapshot.error == -13
                         && snapshot.insertID == largeID + 1 && snapshot.insertCount == 3,
                         "the actual C END decoder freezes all fields before mpv reuses storage")
        }
        precondition(MPVLayerRenderer.endFileSnapshot(mpv_event()) == nil)

        let startRenderer = MPVLayerRenderer()
        startRenderer.cachedPosition = 999
        startRenderer.cachedDuration = 3600
        startRenderer.fileIdentity.begin(handle: handle, generation: 29)
        startRenderer.fileIdentity.bind(handle: handle, generation: 29, entryID: 1)
        startRenderer.handleFileStart(source: newHandle, entryID: 1)
        precondition(startRenderer.cachedPosition == 999, "unowned START cannot reset a new file cache")
        startRenderer.handleFileStart(source: handle, entryID: 1)
        precondition(startRenderer.cachedPosition == 120 && startRenderer.cachedDuration == 0)

        let endRenderer = MPVLayerRenderer()
        for early in [false, true] {
            let generation: UInt = early ? 31 : 30
            endRenderer.fileIdentity.begin(handle: handle, generation: generation)
            if !early { endRenderer.fileIdentity.bind(handle: handle, generation: generation, entryID: 1) }
            endRenderer.fileIdentity.start(handle: handle, entryID: 1)
            endRenderer.deliverEndOutcome(endRenderer.fileIdentity.end(handle: handle, payload: end(1, 4)))
            if early {
                let outcomes = endRenderer.fileIdentity.bind(handle: handle, generation: generation, entryID: 1)
                outcomes.forEach(endRenderer.deliverEndOutcome)
            }
            endRenderer.deliverEndOutcome(endRenderer.fileIdentity.end(handle: handle, payload: end(1, 4)))
            endRenderer.fileIdentity.start(handle: handle, entryID: 1)
            precondition(endRenderer.fileIdentity.receipt == nil,
                         "accepted ERROR is terminal and cannot later become ready")
            DispatchQueue.main.drain()
        }
        precondition(endRenderer.delegate!.errorGenerations == [30, 31] && endRenderer.delegate!.ends == 0)

        for early in [false, true] {
            let rejected = MPVLayerRenderer()
            rejected.identitySource = handle
            rejected.fileIdentity.begin(handle: handle, generation: 40)
            if !early { rejected.fileIdentity.bind(handle: handle, generation: 40, entryID: 1) }
            rejected.fileIdentity.start(handle: handle, entryID: 1)
            rejected.deliverEndOutcome(rejected.fileIdentity.end(handle: handle, payload: end(1, 5, 10, 3)))
            if early {
                rejected.fileIdentity.bind(handle: handle, generation: 40, entryID: 1).forEach(rejected.deliverEndOutcome)
            }
            // Deliver the rejection and a child's EOF completely before the
            // subsequent child's START: host completion must still be absent.
            DispatchQueue.main.drain()
            rejected.deliverEndOutcome(rejected.fileIdentity.end(handle: handle, payload: end(10, 0)))
            DispatchQueue.main.drain()
            precondition(rejected.delegate!.ends == 0 && rejected.delegate!.errors == ["Playlist inputs are not supported by this player"])
            rejected.handleFileStart(source: handle, entryID: 11)
            precondition(rejected.fileIdentity.receipt == nil && rejected.captureProgress(named: "time-pos", value: 100) == nil)
            rejected.reportPause(false)
            rejected.deliverEndOutcome(rejected.fileIdentity.end(handle: handle, payload: end(11, 0)))
            DispatchQueue.main.drain()
            rejected.queue.drain() // Actual production stop helper, outside main delivery.
            precondition(rejected.commands == [["stop"]] && rejected.delegate!.ends == 0 && rejected.delegate!.pauses.isEmpty)
        }

        let replacedStop = MPVLayerRenderer()
        replacedStop.identitySource = handle
        replacedStop.fileIdentity.begin(handle: handle, generation: 41)
        replacedStop.fileIdentity.bind(handle: handle, generation: 41, entryID: 1)
        replacedStop.fileIdentity.start(handle: handle, entryID: 1)
        replacedStop.deliverEndOutcome(replacedStop.fileIdentity.end(handle: handle, payload: end(1, 5, 10, 1)))
        replacedStop.fileIdentity.begin(handle: handle, generation: 42)
        replacedStop.fileIdentity.bind(handle: handle, generation: 42, entryID: 2)
        replacedStop.fileIdentity.start(handle: handle, entryID: 2)
        replacedStop.queue.drain()
        DispatchQueue.main.drain()
        precondition(replacedStop.commands.isEmpty && replacedStop.delegate!.errors.isEmpty,
                     "queued stop and error cannot affect a replacement on the same handle")
        replacedStop.deliverEndOutcome(replacedStop.fileIdentity.end(handle: handle, payload: end(2, 5, 20, 1)))
        replacedStop.mpv = OpaquePointer(bitPattern: 2)
        replacedStop.identityHandle = replacedStop.mpv
        replacedStop.identitySource = newHandle
        replacedStop.queue.drain()
        precondition(replacedStop.commands.isEmpty, "a rejected old handle cannot stop a new native player")
        DispatchQueue.main.drain()

        for reason in [0, 2, 3, 4, 5] {
            let renderer = MPVLayerRenderer()
            renderer.fileIdentity.begin(handle: handle, generation: 43)
            renderer.fileIdentity.bind(handle: handle, generation: 43, entryID: 1)
            renderer.fileIdentity.start(handle: handle, entryID: 1)
            let captured = renderer.fileIdentity.receipt!
            renderer.deliverEndOutcome(renderer.fileIdentity.end(handle: handle, payload: end(1, reason)))
            renderer.deliverEndOutcome(renderer.fileIdentity.end(handle: handle, payload: end(1, reason)))
            renderer.fileIdentity.start(handle: handle, entryID: 10)
            DispatchQueue.main.drain()
            precondition(renderer.delegate!.ends == (reason == 0 ? 1 : 0))
            precondition(renderer.delegate!.errors.count == (reason == 4 || reason == 5 ? 1 : 0))
            precondition(renderer.fileIdentity.receipt == nil)
            if reason != 0 { precondition(!captured.isActive && !renderer.fileIdentity.markPrepared(captured)) }
        }

        var exhausted = MPVFileIdentity()
        exhausted.begin(handle: handle, generation: 44)
        for _ in 0..<65 { exhausted.start(handle: handle, entryID: 1) }
        guard let failure = exhausted.bind(handle: handle, generation: 44, entryID: 1).first,
              case .requestFailure = failure
        else { preconditionFailure("early-event exhaustion must fail explicitly") }
        exhausted.begin(handle: newHandle, generation: 45)
        exhausted.bind(handle: newHandle, generation: 45, entryID: 1)
        exhausted.start(handle: handle, entryID: 1)
        precondition(exhausted.receipt == nil)
        exhausted.start(handle: newHandle, entryID: 1)
        let newHandleReceipt = exhausted.receipt!
        _ = exhausted.end(handle: handle, payload: end(1, 4))
        precondition(exhausted.receipt?.isActive == true)
        exhausted.clear()
        precondition(!newHandleReceipt.isValid)
        print("Renderer production END handling, rejection stops, receipt permits and overflow passed")
    }
}
