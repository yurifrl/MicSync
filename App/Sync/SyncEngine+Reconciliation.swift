import Foundation

// Reconciliation read for the trigger-driven engine: one probe round
// across all adapters. Lives in an extension so SyncEngine stays focused
// on commands; `queue` is internal so this side can deliver on the
// engine queue.

extension SyncEngine {

    // One probe round across all adapters; publishes the snapshot table
    // and drops a goal that no longer has a live session. cb fires on
    // the engine queue with the observed table.
    func reconcileRead(cb: @escaping ([SessionKind: SessionSnapshot]) -> Void) {
        let group = DispatchGroup()
        var observed: [SessionKind: SessionSnapshot] = [:]
        let lock = NSLock()

        for (kind, adapter) in adapters {
            group.enter()
            adapter.probe { snapshot in
                if let snapshot {
                    lock.lock()
                    observed[kind] = snapshot
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: queue) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.snapshots = observed }

            let live = SessionKind.allCases.filter { observed[$0]?.inCall == true }
            Log.debug(.engine, .probeRound, "\(live.count) live of \(observed.count) observed")
            if live.isEmpty, desiredState != nil {
                DispatchQueue.main.async { self.desiredState = nil }
            }
            cb(observed)
        }
    }
}
