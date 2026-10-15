import Foundation

// Replace the delivery queue, not the production callback under test.
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
final class MPVLayerRenderer { func stop() {} }
final class DisplayLayer { func removeFromSuperlayer() {} }
final class AudioSession { func tearDown() {} }
final class PipController {
    var isPictureInPictureActive = true
    var position = 0.0
    var rate = 1.0
    var onPosition: (() -> Void)?
    var onRate: (() -> Void)?
    func setCurrentTimeFromSeconds(_ value: Double) { position = value; onPosition?() }
    func setPlaybackRate(_ value: Double) { rate = value; onRate?() }
    func stopPictureInPicture() {}
}
final class ProgressDelegate {
    var errors: [String] = []
    var readiness: [Bool] = []
    var loading: [Bool] = []
    var tracks: [Bool] = []
    var ends = 0
    var onReadiness: ((MPVPlayerEngine) -> Void)?
    func engineDidReachEnd(_ engine: MPVPlayerEngine) { ends += 1 }
    var positions: [Double] = []
    var pauses: [Bool] = []
    func engine(_ engine: MPVPlayerEngine, didUpdateProgress position: Double,
                duration: Double, cacheSeconds: Double) { positions.append(position) }
    func engine(_ engine: MPVPlayerEngine, didChangePause paused: Bool) { pauses.append(paused) }
    func engine(_ engine: MPVPlayerEngine, didFailWithError message: String) { errors.append(message) }
    func engine(_ engine: MPVPlayerEngine, didBecomeReadyToSeek ready: Bool) {
        readiness.append(ready)
        onReadiness?(engine)
    }
    func engine(_ engine: MPVPlayerEngine, didChangeLoading value: Bool) { loading.append(value) }
    func engine(_ engine: MPVPlayerEngine, didBecomeTracksReady value: Bool) { tracks.append(value) }
}
final class MPVPlayerEngine {
    var isShutDown = false
    var renderer: MPVLayerRenderer? = MPVLayerRenderer()
    var displayLayer = DisplayLayer()
    var audioSession = AudioSession()
    var loadGeneration: UInt = 1
    var cachedPosition = 0.0
    var cachedDuration = 0.0
    var pipController: PipController? = PipController()
    var delegate: ProgressDelegate? = ProgressDelegate()
    var nowPlaying: [Bool] = []
    var onNowPlaying: (() -> Void)?
    func syncNowPlaying(isPlaying: Bool) { nowPlaying.append(isPlaying); onNowPlaying?() }
    func clearNowPlayingInfo() {}
    func setPictureInPictureAutoStartEnabled(_ enabled: Bool) {}
}

@main
struct ProgressGenerationTests {
    static func delivery(_ generation: UInt) -> MPVFileIdentity.Delivery {
        var files = MPVFileIdentity()
        let source = MPVFileIdentity.Handle()
        files.begin(handle: source, generation: generation)
        files.bind(handle: source, generation: generation, entryID: 1)
        files.start(handle: source, entryID: 1)
        return files.receipt!.delivery
    }

    // The renderer's first main hop has accepted this receipt and enters the
    // actual Engine callbacks. Their second hop is held in DeliveryQueue.
    static func enqueueSuccess(_ engine: MPVPlayerEngine, _ renderer: MPVLayerRenderer,
                               _ identity: MPVFileIdentity.Delivery) {
        precondition(identity.isActive)
        engine.renderer(renderer, didUpdatePosition: 44, duration: 99, cacheSeconds: 3, identity: identity)
        engine.renderer(renderer, didChangePause: true, identity: identity)
        engine.renderer(renderer, didChangeLoading: false, identity: identity)
        engine.renderer(renderer, didBecomeReadyToSeek: true, identity: identity)
        engine.renderer(renderer, didBecomeTracksReady: true, identity: identity)
    }

    static func testFinalReceiptFences() {
        let renderer = MPVLayerRenderer()
        let source = MPVFileIdentity.Handle()
        var files = MPVFileIdentity()
        let failed = MPVPlayerEngine()
        files.begin(handle: source, generation: 1)
        files.bind(handle: source, generation: 1, entryID: 1)
        files.start(handle: source, entryID: 1)
        enqueueSuccess(failed, renderer, files.receipt!.delivery)
        _ = files.end(handle: source, payload: MPVEndFile(entryID: 1, reason: 4, error: -13, insertID: 0, insertCount: 0))
        failed.renderer(renderer, didFailWithError: "accepted error", loadGeneration: 1)
        DispatchQueue.main.drain()
        precondition(failed.cachedPosition == 0 && failed.cachedDuration == 0 && failed.pipController!.position == 0)
        precondition(failed.pipController!.rate == 1 && failed.nowPlaying.isEmpty && failed.delegate!.positions.isEmpty && failed.delegate!.pauses.isEmpty)
        precondition(failed.delegate!.tracks.isEmpty && failed.delegate!.readiness == [false] && failed.delegate!.loading == [false])
        precondition(failed.delegate!.errors == ["accepted error"], "ERROR between hops suppresses every queued success effect")

        let redirected = MPVPlayerEngine()
        files.begin(handle: source, generation: 1)
        files.bind(handle: source, generation: 1, entryID: 10)
        files.start(handle: source, entryID: 10)
        enqueueSuccess(redirected, renderer, files.receipt!.delivery)
        _ = files.end(handle: source, payload: MPVEndFile(entryID: 10, reason: 5, error: 0, insertID: 11, insertCount: 2))
        precondition(files.start(handle: source, entryID: 11) == nil)
        redirected.renderer(renderer, didFailWithError: "unsupported playlist", loadGeneration: 1)
        DispatchQueue.main.drain()
        precondition(redirected.cachedPosition == 0 && redirected.cachedDuration == 0 && redirected.pipController!.position == 0)
        precondition(redirected.pipController!.rate == 1 && redirected.nowPlaying.isEmpty && redirected.delegate!.positions.isEmpty && redirected.delegate!.pauses.isEmpty)
        precondition(redirected.delegate!.readiness == [false] && redirected.delegate!.tracks.isEmpty && redirected.delegate!.loading == [false],
                     "redirect rejection revokes first-hop success before final delivery within the same generation")
        precondition(redirected.delegate!.errors == ["unsupported playlist"])
        files.begin(handle: source, generation: 1)
        files.bind(handle: source, generation: 1, entryID: 20)
        files.start(handle: source, entryID: 20)
        enqueueSuccess(redirected, renderer, files.receipt!.delivery)
        DispatchQueue.main.drain()
        precondition(redirected.delegate!.positions == [44] && redirected.delegate!.pauses == [true])
        precondition(redirected.delegate!.readiness == [false, true] && redirected.delegate!.tracks == [true] && redirected.delegate!.loading == [false, false])

        let pending = MPVPlayerEngine()
        files.begin(handle: source, generation: 1)
        pending.renderer(renderer, didChangeLoading: true, identity: files.pendingDelivery!)
        files.bind(handle: source, generation: 1, entryID: 20)
        files.start(handle: source, entryID: 20)
        DispatchQueue.main.drain()
        precondition(pending.delegate!.loading.isEmpty, "request loading cannot run after file readiness has taken ownership")
        files.begin(handle: source, generation: 1)
        pending.renderer(renderer, didChangeLoading: true, identity: files.pendingDelivery!)
        _ = files.invalidate(handle: source)
        DispatchQueue.main.drain()
        precondition(pending.delegate!.loading.isEmpty, "pre-START failure revokes initial loading at final delivery")
        files.begin(handle: source, generation: 1)
        pending.renderer(renderer, didChangeLoading: true, identity: files.pendingDelivery!)
        pending.loadGeneration = 2
        DispatchQueue.main.drain()
        precondition(pending.delegate!.loading.isEmpty, "request loading also checks Engine generation")

        let stopped = MPVPlayerEngine()
        files.begin(handle: source, generation: 1)
        files.bind(handle: source, generation: 1, entryID: 21)
        files.start(handle: source, entryID: 21)
        enqueueSuccess(stopped, renderer, files.receipt!.delivery)
        stopped.shutdown()
        DispatchQueue.main.drain()
        precondition(stopped.cachedPosition == 0 && stopped.delegate!.positions.isEmpty && stopped.delegate!.pauses.isEmpty)
        precondition(stopped.delegate!.readiness.isEmpty && stopped.delegate!.loading.isEmpty && stopped.delegate!.tracks.isEmpty,
                     "actual Engine shutdown invalidates all queued load-derived callbacks")

        let reentered = MPVPlayerEngine()
        files.begin(handle: source, generation: 1)
        files.bind(handle: source, generation: 1, entryID: 30)
        files.start(handle: source, entryID: 30)
        let identity = files.receipt!.delivery
        reentered.renderer(renderer, didUpdatePosition: 42, duration: 99, cacheSeconds: 0, identity: identity)
        reentered.pipController!.onPosition = {
            _ = files.end(handle: source, payload: MPVEndFile(entryID: 30, reason: 4, error: -13, insertID: 0, insertCount: 0))
        }
        DispatchQueue.main.drain()
        precondition(reentered.delegate!.positions.isEmpty, "PiP reentry must revalidate before JS notification")
        files.begin(handle: source, generation: 1)
        files.bind(handle: source, generation: 1, entryID: 31)
        files.start(handle: source, entryID: 31)
        reentered.renderer(renderer, didChangePause: true, identity: files.receipt!.delivery)
        reentered.pipController!.onRate = {
            _ = files.end(handle: source, payload: MPVEndFile(entryID: 31, reason: 4, error: -13, insertID: 0, insertCount: 0))
        }
        DispatchQueue.main.drain()
        precondition(reentered.nowPlaying.isEmpty && reentered.delegate!.pauses.isEmpty,
                     "PiP pause reentry cannot update Now Playing or JS after permit revocation")
        reentered.pipController!.onRate = nil
        files.begin(handle: source, generation: 1)
        files.bind(handle: source, generation: 1, entryID: 32)
        files.start(handle: source, entryID: 32)
        reentered.renderer(renderer, didChangePause: true, identity: files.receipt!.delivery)
        reentered.onNowPlaying = {
            _ = files.end(handle: source, payload: MPVEndFile(entryID: 32, reason: 4, error: -13, insertID: 0, insertCount: 0))
        }
        DispatchQueue.main.drain()
        precondition(reentered.nowPlaying == [false] && reentered.delegate!.pauses.isEmpty,
                     "Now Playing reentry must revalidate before the JS pause notification")

        let readyReentry = MPVPlayerEngine()
        files.begin(handle: source, generation: 1)
        files.bind(handle: source, generation: 1, entryID: 33)
        files.start(handle: source, entryID: 33)
        let prepared = files.receipt!.delivery
        readyReentry.delegate!.onReadiness = { engine in
            guard prepared.isActive else { return }
            _ = files.end(handle: source, payload: MPVEndFile(entryID: 33, reason: 4, error: -13, insertID: 0, insertCount: 0))
            engine.renderer(renderer, didFailWithError: "readiness reentry", loadGeneration: 1)
        }
        readyReentry.renderer(renderer, didBecomeReadyToSeek: true, identity: prepared)
        enqueueSuccess(readyReentry, renderer, prepared)
        DispatchQueue.main.drain()
        precondition(readyReentry.cachedPosition == 0 && readyReentry.nowPlaying.isEmpty && readyReentry.delegate!.pauses.isEmpty)
        precondition(readyReentry.delegate!.readiness == [true, false] && readyReentry.delegate!.tracks.isEmpty
                     && readyReentry.delegate!.loading == [false] && readyReentry.delegate!.errors == ["readiness reentry"],
                     "reentrant readiness failure suppresses the remaining queued success callbacks")
    }

    static func main() {
        testFinalReceiptFences()

        let engine = MPVPlayerEngine()
        let renderer = MPVLayerRenderer()
        engine.renderer(renderer, didUpdatePosition: 2400, duration: 3600,
                        cacheSeconds: 2, identity: delivery(1))
        engine.loadGeneration = 2 // A new load and onLoad precede delivery.
        DispatchQueue.main.drain()
        precondition(engine.cachedPosition == 0 && engine.cachedDuration == 0,
                     "an outgoing tick cannot overwrite the new load's position cache")
        precondition(engine.pipController?.position == 0 && engine.delegate!.positions.isEmpty,
                     "an outgoing tick cannot reach PiP or JS after replacement")

        engine.renderer(renderer, didUpdatePosition: 30, duration: 1800,
                        cacheSeconds: 2, identity: delivery(2))
        DispatchQueue.main.drain()
        precondition(engine.cachedPosition == 30 && engine.delegate!.positions == [30],
                     "the accepted load reports progress normally")

        // A forced reload of the exact same URL still changes generation.
        engine.renderer(renderer, didUpdatePosition: 40, duration: 1800,
                        cacheSeconds: 2, identity: delivery(2))
        engine.loadGeneration = 3
        DispatchQueue.main.drain()
        precondition(engine.cachedPosition == 30 && engine.delegate!.positions == [30],
                     "URL equality cannot authorize a tick from before a same-URL reload")

        engine.renderer(renderer, didUpdatePosition: 50, duration: 1800,
                        cacheSeconds: 2, identity: delivery(3))
        engine.loadGeneration = 4 // shutdown() invalidates pending delivery.
        DispatchQueue.main.drain()
        precondition(engine.cachedPosition == 30 && engine.pipController?.position == 30,
                     "shutdown invalidates outstanding progress before any mutation")
        engine.renderer(renderer, didChangePause: true, identity: delivery(4))
        engine.loadGeneration = 5
        DispatchQueue.main.drain()
        precondition(engine.pipController?.rate == 1 && engine.nowPlaying.isEmpty && engine.delegate!.pauses.isEmpty,
                     "an old pause cannot mutate PiP, Now Playing or JS at final delivery")

        engine.renderer(renderer, didChangePause: true, identity: delivery(5))
        DispatchQueue.main.drain()
        precondition(engine.pipController?.rate == 0 && engine.nowPlaying == [false] && engine.delegate!.pauses == [true],
                     "the accepted pause reaches PiP, Now Playing and JS")
        engine.renderer(renderer, didChangePause: false, identity: delivery(5))
        engine.loadGeneration = 6 // shutdown invalidates pause delivery too
        DispatchQueue.main.drain()
        precondition(engine.pipController?.rate == 0 && engine.delegate!.pauses == [true])
        engine.renderer(renderer, didFailWithError: "old overflow", loadGeneration: 6)
        engine.loadGeneration = 7
        DispatchQueue.main.drain()
        precondition(engine.delegate!.errors.isEmpty && engine.delegate!.readiness.isEmpty && engine.delegate!.loading.isEmpty,
                     "a stale overflow cannot change replacement readiness/loading or show its error")
        engine.renderer(renderer, didFailWithError: "current overflow", loadGeneration: 7)
        DispatchQueue.main.drain()
        precondition(engine.delegate!.errors == ["current overflow"] && engine.delegate!.readiness == [false]
                     && engine.delegate!.loading == [false], "an accepted overflow reaches the existing error path")
        engine.renderer(renderer, didFailWithError: "shutdown overflow", loadGeneration: 7)
        engine.renderer(renderer, didUpdatePosition: 900, duration: 1800, cacheSeconds: 2, identity: delivery(7))
        engine.renderer(renderer, didChangePause: false, identity: delivery(7))
        engine.shutdown() // Actual production shutdown body, not a simulated increment.
        DispatchQueue.main.drain()
        precondition(engine.loadGeneration == 8 && engine.delegate!.errors == ["current overflow"]
                     && engine.cachedPosition == 30 && engine.delegate!.pauses == [true],
                     "actual shutdown suppresses queued error, progress and pause delivery")
        engine.shutdown()
        precondition(engine.loadGeneration == 8, "shutdown remains idempotent")
        let eofEngine = MPVPlayerEngine()
        var files = MPVFileIdentity()
        let source = MPVFileIdentity.Handle()
        files.begin(handle: source, generation: 1)
        files.bind(handle: source, generation: 1, entryID: 1)
        files.start(handle: source, entryID: 1)
        let oldFile = files.receipt!
        _ = files.end(handle: source, payload: MPVEndFile(entryID: 1, reason: 0, error: 0, insertID: 0, insertCount: 0))
        eofEngine.rendererDidReachEnd(renderer, identity: oldFile)
        files.begin(handle: source, generation: 1)
        files.bind(handle: source, generation: 1, entryID: 3)
        files.start(handle: source, entryID: 3)
        DispatchQueue.main.drain()
        precondition(eofEngine.delegate!.ends == 0, "final EOF rejects a revoked physical permit even before Engine generation changes")
        let replaced = files.receipt!
        eofEngine.rendererDidReachEnd(renderer, identity: replaced)
        eofEngine.loadGeneration = 2
        DispatchQueue.main.drain()
        precondition(eofEngine.delegate!.ends == 0, "final EOF also rejects a replaced load generation")
        files.begin(handle: source, generation: 2)
        files.bind(handle: source, generation: 2, entryID: 2)
        files.start(handle: source, entryID: 2)
        let accepted = files.receipt!
        _ = files.end(handle: source, payload: MPVEndFile(entryID: 2, reason: 0, error: 0, insertID: 0, insertCount: 0))
        eofEngine.rendererDidReachEnd(renderer, identity: accepted)
        DispatchQueue.main.drain()
        precondition(eofEngine.delegate!.ends == 1, "a valid current EOF reaches the player")
        eofEngine.rendererDidReachEnd(renderer, identity: accepted)
        eofEngine.shutdown()
        DispatchQueue.main.drain()
        precondition(eofEngine.delegate!.ends == 1, "actual shutdown suppresses queued EOF")
        let reentered = MPVPlayerEngine()
        reentered.delegate!.onReadiness = { $0.loadGeneration += 1 }
        reentered.renderer(renderer, didFailWithError: "replaced during callback", loadGeneration: 1)
        DispatchQueue.main.drain()
        precondition(reentered.delegate!.errors.isEmpty && reentered.delegate!.loading.isEmpty,
                     "readiness reentry cannot apply an old failure to a replacement load")
        print("Native progress, pause and terminal-error final-delivery generations passed")
    }
}
