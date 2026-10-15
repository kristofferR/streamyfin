import Foundation

struct MPVEndFile {
    let entryID: Int64
    let reason: Int
    let error: Int
    let insertID: Int64
    let insertCount: Int
}

/// Owned by the renderer queue; receipts retain a thread-safe delivery permit.
struct MPVFileIdentity {
    final class Handle {}
    final class Permit {
        private let lock = NSLock()
        private var valid = true
        private var active = true
        var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
        var isActive: Bool { lock.lock(); defer { lock.unlock() }; return valid && active }
        func terminate(allowCapturedMedia: Bool) { lock.lock(); active = allowCapturedMedia; lock.unlock() }
        func invalidate() { lock.lock(); valid = false; active = false; lock.unlock() }
    }
    struct Delivery {
        let loadGeneration: UInt
        fileprivate let permit: Permit
        var isActive: Bool { permit.isActive }
    }
    struct Receipt {
        let handle: Handle
        let entryID: Int64
        let loadGeneration: UInt
        fileprivate let permit: Permit
        var isValid: Bool { permit.isValid }
        var isActive: Bool { permit.isActive }
        var delivery: Delivery { Delivery(loadGeneration: loadGeneration, permit: permit) }
    }
    enum Stage { case pending, prepared, terminal }
    enum EndReason { case eof, stopped, error(String) }
    enum EndOutcome {
        case ignored
        case terminal(Receipt, EndReason)
        case requestFailure(UInt, String)
    }
    private enum Early { case start(Int64?), end(MPVEndFile) }
    private static let maxEarlyEvents = 64
    private var requestedHandle: Handle?
    private var requestedGeneration: UInt = 0
    private var rootID: Int64?
    private var bindingPending = false
    private var overflowed = false
    private var activeReceipt: Receipt?
    private var pendingPermit: Permit?
    private var stage = Stage.pending
    private var early: [Early] = []

    mutating func begin(handle: Handle, generation: UInt) {
        clear()
        requestedHandle = handle
        requestedGeneration = generation
        bindingPending = true
        pendingPermit = Permit()
    }

    @discardableResult
    mutating func bind(handle: Handle, generation: UInt, entryID: Int64?) -> [EndOutcome] {
        guard requestedHandle === handle, requestedGeneration == generation, bindingPending else { return [] }
        bindingPending = false
        guard !overflowed, let entryID, entryID >= 0 else {
            clear()
            return [.requestFailure(generation, "Could not identify the loaded mpv file")]
        }
        rootID = entryID
        let events = early
        early = []
        var outcomes: [EndOutcome] = []
        for event in events {
            switch event {
            case .start(let id): start(handle: handle, entryID: id)
            case .end(let payload): outcomes.append(end(handle: handle, payload: payload))
            }
        }
        return outcomes
    }

    @discardableResult
    mutating func start(handle: Handle, entryID: Int64?) -> Receipt? {
        guard requestedHandle === handle else { return nil }
        if bindingPending { retain(.start(entryID)); return nil }
        guard stage != .terminal else { return nil }
        // Initial loading is request-owned only until an actual file starts.
        pendingPermit?.invalidate()
        pendingPermit = nil
        guard let entryID, entryID == rootID else {
            activeReceipt?.permit.invalidate()
            activeReceipt = nil
            return nil
        }
        activeReceipt?.permit.invalidate()
        activeReceipt = Receipt(handle: handle, entryID: entryID,
                                loadGeneration: requestedGeneration, permit: Permit())
        stage = .pending
        return activeReceipt
    }

    @discardableResult
    mutating func end(handle: Handle, entryID: Int64?) -> EndOutcome {
        end(handle: handle, payload: MPVEndFile(entryID: entryID ?? -1, reason: 2, error: 0, insertID: 0, insertCount: 0))
    }

    mutating func end(handle: Handle, payload: MPVEndFile) -> EndOutcome {
        guard requestedHandle === handle else { return .ignored }
        if bindingPending { retain(.end(payload)); return .ignored }
        guard stage != .terminal, let identity = activeReceipt, identity.entryID == payload.entryID else { return .ignored }
        switch payload.reason {
        case 0: return terminate(identity, reason: .eof)
        case 5: return terminate(identity, reason: .error("Playlist inputs are not supported by this player"))
        case 2, 3: return terminate(identity, reason: .stopped)
        default: return terminate(identity, reason: .error("mpv playback failed (error \(payload.error))"))
        }
    }

    private mutating func terminate(_ identity: Receipt, reason: EndReason) -> EndOutcome {
        stage = .terminal
        // Preserve already captured physical progress before single-file EOF.
        // Failure suppresses success; replacement/clear revokes final delivery.
        if case .eof = reason { identity.permit.terminate(allowCapturedMedia: true) }
        else { identity.permit.terminate(allowCapturedMedia: false) }
        return .terminal(identity, reason)
    }

    private mutating func retain(_ event: Early) {
        guard !overflowed else { return }
        if early.count == Self.maxEarlyEvents { overflowed = true; early = [] }
        else { early.append(event) }
    }

    mutating func markPrepared(_ receipt: Receipt) -> Bool {
        guard stage == .pending, activeReceipt?.permit === receipt.permit, receipt.isActive else { return false }
        stage = .prepared
        return true
    }

    mutating func clear() {
        pendingPermit?.invalidate()
        pendingPermit = nil
        activeReceipt?.permit.invalidate()
        activeReceipt = nil
        requestedHandle = nil
        rootID = nil
        bindingPending = false
        overflowed = false
        stage = .pending
        early = []
    }

    func ownsTerminal(_ identity: Receipt) -> Bool {
        stage == .terminal && activeReceipt?.permit === identity.permit && identity.isValid
    }

    mutating func invalidate(handle: Handle) -> UInt? {
        guard requestedHandle === handle else { return nil }
        let generation = requestedGeneration
        clear()
        return generation
    }

    var receipt: Receipt? { stage == .terminal ? nil : activeReceipt }
    var pendingDelivery: Delivery? {
        pendingPermit.map { Delivery(loadGeneration: requestedGeneration, permit: $0) }
    }
}

struct MPVProgressReceipt {
    let identity: MPVFileIdentity.Receipt
    let position: Double
    let duration: Double
    let cacheSeconds: Double
}

struct MPVPauseReceipt {
    let identity: MPVFileIdentity.Receipt
    let isPaused: Bool
    let progress: MPVProgressReceipt?
}
