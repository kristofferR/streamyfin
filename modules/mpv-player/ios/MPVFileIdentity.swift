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
    struct Receipt {
        let handle: Handle
        let entryID: Int64
        let loadGeneration: UInt
        fileprivate let permit: Permit
        var isValid: Bool { permit.isValid }
        var isActive: Bool { permit.isActive }
    }
    enum Stage { case pending, prepared, terminal }
    enum EndReason { case eof, stopped, error(String) }
    enum EndOutcome {
        case ignored, redirected
        case terminal(Receipt, EndReason)
        case requestFailure(UInt, String)
    }
    private enum Early { case start(Int64?), end(MPVEndFile) }
    private struct Range {
        let first: Int64
        let last: Int64
        func contains(_ entry: Int64) -> Bool { entry >= first && entry <= last }
    }
    private static let maxEarlyEvents = 64
    private static let maxRedirects = 64
    private var requestedHandle: Handle?
    private var requestedGeneration: UInt = 0
    private var rootID: Int64?
    private var bindingPending = false
    private var overflowed = false
    private var activeReceipt: Receipt?
    private var stage = Stage.pending
    private var mayContinueAfterEof = false
    private var early: [Early] = []
    private var ranges: [Range] = []
    private var retired: Set<Int64> = []

    mutating func begin(handle: Handle, generation: UInt) {
        clear()
        requestedHandle = handle
        requestedGeneration = generation
        bindingPending = true
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
        guard stage != .terminal || mayContinueAfterEof else { return nil }
        guard let entryID, !retired.contains(entryID),
              entryID == rootID || ranges.contains(where: { $0.contains(entryID) }) else {
            activeReceipt?.permit.invalidate()
            activeReceipt = nil
            return nil
        }
        activeReceipt?.permit.invalidate()
        activeReceipt = Receipt(handle: handle, entryID: entryID,
                                loadGeneration: requestedGeneration, permit: Permit())
        stage = .pending
        mayContinueAfterEof = false
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
        if payload.reason == 5 {
            let count = payload.insertCount
            let first = payload.insertID
            let lastAllocated = ranges.map(\.last).max() ?? rootID ?? identity.entryID
            // Pinned mpv transfers assign ++id_alloc in one loop; the actual
            // subsequent START selects a member. See END_FILE-evidence.md.
            guard count > 0, first > max(identity.entryID, lastAllocated),
                  first <= Int64.max - (Int64(count) - 1), ranges.count < Self.maxRedirects else {
                return terminate(identity, reason: .error("Invalid or exhausted mpv playlist lineage"))
            }
            ranges.append(Range(first: first, last: first + (Int64(count) - 1)))
            retired.insert(identity.entryID)
            identity.permit.invalidate()
            activeReceipt = nil
            stage = .pending
            return .redirected
        }
        switch payload.reason {
        case 0:
            mayContinueAfterEof = true
            return terminate(identity, reason: .eof)
        case 2, 3: return terminate(identity, reason: .stopped)
        default: return terminate(identity, reason: .error("mpv playback failed (error \(payload.error))"))
        }
    }

    private mutating func terminate(_ identity: Receipt, reason: EndReason) -> EndOutcome {
        stage = .terminal
        // Keep already captured physical progress before normal EOF. Failure
        // suppresses success, and a later START invalidates either permit.
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
        activeReceipt?.permit.invalidate()
        activeReceipt = nil
        requestedHandle = nil
        rootID = nil
        bindingPending = false
        overflowed = false
        stage = .pending
        mayContinueAfterEof = false
        early = []
        ranges = []
        retired = []
    }

    mutating func invalidate(handle: Handle) -> UInt? {
        guard requestedHandle === handle else { return nil }
        let generation = requestedGeneration
        clear()
        return generation
    }

    var receipt: Receipt? { stage == .terminal ? nil : activeReceipt }
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
