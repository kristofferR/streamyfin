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
    func setCurrentTimeFromSeconds(_ value: Double) { position = value }
    func setPlaybackRate(_ value: Double) { rate = value }
    func stopPictureInPicture() {}
}
final class ProgressDelegate {
    var errors: [String] = []
    var readiness: [Bool] = []
    var loading: [Bool] = []
    var positions: [Double] = []
    var pauses: [Bool] = []
    func engine(_ engine: MPVPlayerEngine, didUpdateProgress position: Double,
                duration: Double, cacheSeconds: Double) { positions.append(position) }
    func engine(_ engine: MPVPlayerEngine, didChangePause paused: Bool) { pauses.append(paused) }
    func engine(_ engine: MPVPlayerEngine, didFailWithError message: String) { errors.append(message) }
    func engine(_ engine: MPVPlayerEngine, didBecomeReadyToSeek ready: Bool) { readiness.append(ready) }
    func engine(_ engine: MPVPlayerEngine, didChangeLoading value: Bool) { loading.append(value) }
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
    func syncNowPlaying(isPlaying: Bool) { nowPlaying.append(isPlaying) }
    func clearNowPlayingInfo() {}
    func setPictureInPictureAutoStartEnabled(_ enabled: Bool) {}
}

@main
struct ProgressGenerationTests {
    static func main() {
        let engine = MPVPlayerEngine()
        let renderer = MPVLayerRenderer()
        engine.renderer(renderer, didUpdatePosition: 2400, duration: 3600,
                        cacheSeconds: 2, loadGeneration: 1)
        engine.loadGeneration = 2 // A new load and onLoad precede delivery.
        DispatchQueue.main.drain()
        precondition(engine.cachedPosition == 0 && engine.cachedDuration == 0,
                     "an outgoing tick cannot overwrite the new load's position cache")
        precondition(engine.pipController?.position == 0 && engine.delegate!.positions.isEmpty,
                     "an outgoing tick cannot reach PiP or JS after replacement")

        engine.renderer(renderer, didUpdatePosition: 30, duration: 1800,
                        cacheSeconds: 2, loadGeneration: 2)
        DispatchQueue.main.drain()
        precondition(engine.cachedPosition == 30 && engine.delegate!.positions == [30],
                     "the accepted load reports progress normally")

        // A forced reload of the exact same URL still changes generation.
        engine.renderer(renderer, didUpdatePosition: 40, duration: 1800,
                        cacheSeconds: 2, loadGeneration: 2)
        engine.loadGeneration = 3
        DispatchQueue.main.drain()
        precondition(engine.cachedPosition == 30 && engine.delegate!.positions == [30],
                     "URL equality cannot authorize a tick from before a same-URL reload")

        engine.renderer(renderer, didUpdatePosition: 50, duration: 1800,
                        cacheSeconds: 2, loadGeneration: 3)
        engine.loadGeneration = 4 // shutdown() invalidates pending delivery.
        DispatchQueue.main.drain()
        precondition(engine.cachedPosition == 30 && engine.pipController?.position == 30,
                     "shutdown invalidates outstanding progress before any mutation")
        engine.renderer(renderer, didChangePause: true, loadGeneration: 4)
        engine.loadGeneration = 5
        DispatchQueue.main.drain()
        precondition(engine.pipController?.rate == 1 && engine.nowPlaying.isEmpty && engine.delegate!.pauses.isEmpty,
                     "an old pause cannot mutate PiP, Now Playing or JS at final delivery")

        engine.renderer(renderer, didChangePause: true, loadGeneration: 5)
        DispatchQueue.main.drain()
        precondition(engine.pipController?.rate == 0 && engine.nowPlaying == [false] && engine.delegate!.pauses == [true],
                     "the accepted pause reaches PiP, Now Playing and JS")
        engine.renderer(renderer, didChangePause: false, loadGeneration: 5)
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
        engine.renderer(renderer, didUpdatePosition: 900, duration: 1800, cacheSeconds: 2, loadGeneration: 7)
        engine.renderer(renderer, didChangePause: false, loadGeneration: 7)
        engine.shutdown() // Actual production shutdown body, not a simulated increment.
        DispatchQueue.main.drain()
        precondition(engine.loadGeneration == 8 && engine.delegate!.errors == ["current overflow"]
                     && engine.cachedPosition == 30 && engine.delegate!.pauses == [true],
                     "actual shutdown suppresses queued error, progress and pause delivery")
        engine.shutdown()
        precondition(engine.loadGeneration == 8, "shutdown remains idempotent")
        print("Native progress, pause and terminal-error final-delivery generations passed")
    }
}
