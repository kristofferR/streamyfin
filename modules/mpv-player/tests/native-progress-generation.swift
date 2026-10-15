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
final class MPVLayerRenderer {}
final class PipController {
    var isPictureInPictureActive = true
    var position = 0.0
    func setCurrentTimeFromSeconds(_ value: Double) { position = value }
}
final class ProgressDelegate {
    var positions: [Double] = []
    func engine(_ engine: MPVPlayerEngine, didUpdateProgress position: Double,
                duration: Double, cacheSeconds: Double) { positions.append(position) }
}
final class MPVPlayerEngine {
    var loadGeneration: UInt = 1
    var cachedPosition = 0.0
    var cachedDuration = 0.0
    var pipController: PipController? = PipController()
    var delegate: ProgressDelegate? = ProgressDelegate()
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
        print("Native progress generations: 4 scenarios passed")
    }
}
