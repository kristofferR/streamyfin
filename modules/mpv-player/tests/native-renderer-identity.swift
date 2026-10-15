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
        startRenderer.deliverEndOutcome(startRenderer.fileIdentity.end(handle: handle, payload: end(1, 5, 10, 2)))
        startRenderer.cachedPosition = 500
        startRenderer.handleFileStart(source: handle, entryID: 11)
        precondition(startRenderer.cachedPosition == 120 && startRenderer.fileIdentity.receipt?.entryID == 11,
                     "actual child START clears the previous physical clock without inventing a progress callback")

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

        var lineage = MPVFileIdentity()
        lineage.begin(handle: handle, generation: 40)
        lineage.start(handle: handle, entryID: 1)
        _ = lineage.end(handle: handle, payload: end(1, 5, 10, 3))
        lineage.start(handle: handle, entryID: 12)
        _ = lineage.end(handle: handle, payload: end(12, 5, 20, 2))
        lineage.start(handle: handle, entryID: 21)
        _ = lineage.bind(handle: handle, generation: 40, entryID: 1)
        let ready = lineage.receipt!
        precondition(ready.entryID == 21 && lineage.markPrepared(ready),
                     "early nested redirects follow the actual non-first child START")
        _ = lineage.end(handle: handle, payload: end(999, 4))
        precondition(lineage.receipt?.entryID == 21, "unrelated END cannot terminate the accepted child")
        lineage.start(handle: handle, entryID: 999)
        precondition(lineage.receipt == nil && !ready.isValid)
        lineage.start(handle: handle, entryID: 20)
        precondition(lineage.receipt?.entryID == 20)
        let firstChild = lineage.receipt!
        _ = lineage.end(handle: handle, payload: end(20, 0))
        lineage.start(handle: handle, entryID: 10)
        precondition(lineage.receipt?.entryID == 10 && !firstChild.isValid,
                     "normal EOF can continue to another proven child, retiring old delivery")

        for reason in [2, 3, 4] {
            lineage.begin(handle: handle, generation: 41)
            lineage.bind(handle: handle, generation: 41, entryID: 1)
            lineage.start(handle: handle, entryID: 1)
            let outcome = lineage.end(handle: handle, payload: end(1, reason))
            let renderer = MPVLayerRenderer()
            renderer.deliverEndOutcome(outcome)
            DispatchQueue.main.drain()
            precondition(renderer.delegate!.ends == 0 && renderer.delegate!.errors.count == (reason == 4 ? 1 : 0))
            lineage.start(handle: handle, entryID: 1)
            precondition(lineage.receipt == nil, "STOP, QUIT and ERROR cannot acknowledge later success")
        }

        for (first, count) in [(Int64(0), 1), (10, 0), (10, -1), (Int64.max, 2)] {
            lineage.begin(handle: handle, generation: 42)
            lineage.bind(handle: handle, generation: 42, entryID: 1)
            lineage.start(handle: handle, entryID: 1)
            guard case .terminal(_, .error) = lineage.end(handle: handle, payload: end(1, 5, first, count))
            else { preconditionFailure("malformed inserted range must fail explicitly") }
        }
        lineage.begin(handle: handle, generation: 43)
        lineage.bind(handle: handle, generation: 43, entryID: 1)
        lineage.start(handle: handle, entryID: 1)
        for entry in Int64(1)...64 {
            _ = lineage.end(handle: handle, payload: end(entry, 5, entry + 1, 1))
            lineage.start(handle: handle, entryID: entry + 1)
        }
        guard case .terminal(_, .error) = lineage.end(handle: handle, payload: end(65, 5, 66, 1))
        else { preconditionFailure("lineage exhaustion must fail explicitly") }
        lineage.begin(handle: handle, generation: 44)
        for _ in 0..<65 { lineage.start(handle: handle, entryID: 1) }
        let exhausted = lineage.bind(handle: handle, generation: 44, entryID: 1)
        guard let firstFailure = exhausted.first, case .requestFailure = firstFailure
        else { preconditionFailure("early-event exhaustion must fail explicitly") }
        lineage.begin(handle: newHandle, generation: 45)
        lineage.bind(handle: newHandle, generation: 45, entryID: 10)
        lineage.start(handle: handle, entryID: 10)
        precondition(lineage.receipt == nil, "old handle cannot reuse a redirected numeric ID")
        lineage.start(handle: newHandle, entryID: 10)
        let stopped = lineage.receipt!
        _ = lineage.end(handle: handle, payload: end(10, 4))
        precondition(lineage.receipt?.isActive == true, "old handle END cannot terminate a reused ID")
        lineage.clear()
        precondition(!stopped.isValid)

        let eofRenderer = MPVLayerRenderer()
        eofRenderer.fileIdentity.begin(handle: handle, generation: 50)
        eofRenderer.fileIdentity.bind(handle: handle, generation: 50, entryID: 1)
        eofRenderer.fileIdentity.start(handle: handle, entryID: 1)
        eofRenderer.deliverEndOutcome(eofRenderer.fileIdentity.end(handle: handle, payload: end(1, 5, 10, 2)))
        eofRenderer.fileIdentity.start(handle: handle, entryID: 10)
        eofRenderer.deliverEndOutcome(eofRenderer.fileIdentity.end(handle: handle, payload: end(10, 0)))
        eofRenderer.fileIdentity.start(handle: handle, entryID: 11)
        DispatchQueue.main.drain()
        precondition(eofRenderer.delegate!.ends == 0, "actual handler suppresses EOF retired before main delivery")
        let pendingReady = eofRenderer.fileIdentity.receipt!
        eofRenderer.reportPause(false)
        eofRenderer.deliverEndOutcome(eofRenderer.fileIdentity.end(handle: handle, payload: end(11, 4)))
        precondition(!pendingReady.isActive && !eofRenderer.fileIdentity.markPrepared(pendingReady),
                     "terminal failure suppresses pending readiness and success")
        DispatchQueue.main.drain()
        precondition(eofRenderer.delegate!.errors.count == 1 && eofRenderer.delegate!.pauses.isEmpty)
        print("Renderer production END decoding/handling, lineage, progress/pause and overflow passed")
    }
}
