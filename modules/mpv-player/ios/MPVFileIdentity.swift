/// Owned by the renderer's mpv queue. Entry IDs belong to a native handle,
/// and a request can be replaced before it produces any START_FILE event.
struct MPVFileIdentity {
    final class Handle {}

    struct Receipt {
        let handle: Handle
        let entryID: Int64
        let loadGeneration: UInt
    }

    private var requestedHandle: Handle?
    private var requestedGeneration: UInt = 0
    private var requestedEntryID: Int64?
    private var startedHandle: Handle?
    private var startedEntryID: Int64?

    mutating func begin(handle: Handle, generation: UInt) {
        requestedHandle = handle
        requestedGeneration = generation
        requestedEntryID = nil
    }

    mutating func bind(handle: Handle, generation: UInt, entryID: Int64?) {
        guard requestedHandle === handle, requestedGeneration == generation else { return }
        requestedEntryID = entryID.flatMap { $0 >= 0 ? $0 : nil }
    }

    mutating func start(handle: Handle, entryID: Int64?) {
        startedHandle = handle
        startedEntryID = entryID.flatMap { $0 >= 0 ? $0 : nil }
    }

    mutating func end(handle: Handle, entryID: Int64?) {
        guard startedHandle === handle,
              entryID == nil || startedEntryID == entryID else { return }
        startedEntryID = nil
    }

    mutating func clear() {
        requestedHandle = nil
        requestedEntryID = nil
        startedHandle = nil
        startedEntryID = nil
    }

    var receipt: Receipt? {
        guard let handle = requestedHandle, startedHandle === handle,
              let entryID = requestedEntryID, startedEntryID == entryID else { return nil }
        return Receipt(handle: handle, entryID: entryID, loadGeneration: requestedGeneration)
    }
}

struct MPVProgressReceipt {
    let identity: MPVFileIdentity.Receipt
    let position: Double
    let duration: Double
    let cacheSeconds: Double
}
