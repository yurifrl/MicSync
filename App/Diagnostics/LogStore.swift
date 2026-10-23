import Foundation
import Combine

// The single diagnostics sink. Gated capture (debug console closed = zero
// work beyond one bool check), a fixed-capacity ring so a session can
// never grow without bound, and coalesced main-queue publishing so a
// burst of events re-renders the console once, not once per event.
//
// Thread model: `append` is called from any queue (engine, adapter queues,
// main) and takes the lock only when capture is on. Publishing happens on
// the main queue after a coalescing interval; reads of `entries` happen on
// the main queue only.
final class LogStore: ObservableObject {
    static let shared = LogStore()

    // Burst burst-coalescing: mutations notify subscribers at most this often.
    private static let publishInterval: TimeInterval = 0.25
    // Ring capacity; captured entries beyond this drop oldest-first.
    // Readable by the console footer.
    static let publishedCapacity = 1000

    @Published private(set) var entries: [LogEntry] = []

    private var lock = NSLock()
    private var enabled = false
    private var buffer: [LogEntry] = [] // ring body; oldest at index 0
    private var nextID = 0

    private var publishScheduled = false

    // Toggle point for the whole pipeline. Turning capture off clears the
    // buffer — session-scoped by design (also keeps App-memory-bounds).
    func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        if !on { buffer.removeAll(keepingCapacity: false) }
        lock.unlock()
        objectWillChange.send()
    }

    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    func append(_ level: LogLevel, _ category: LogCategory, _ metric: LogMetric?, _ message: String) {
        lock.lock()
        guard enabled else {
            lock.unlock()
            return
        }
        let entry = LogEntry(
            id: nextID,
            time: Date(),
            level: level,
            category: category,
            metric: metric,
            message: message
        )
        nextID += 1
        if buffer.count >= Self.publishedCapacity {
            buffer.removeFirst(buffer.count - Self.publishedCapacity + 1)
        }
        buffer.append(entry)
        lock.unlock()

        schedulePublish()
    }

    // Console "Clear" button: wipes the visible buffer, keeps capture on.
    func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        objectWillChange.send()
    }

    private func schedulePublish() {
        // Called on any queue after a successful append.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.publishScheduled else { return }
            self.publishScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishInterval) { [weak self] in
                guard let self else { return }
                self.publishScheduled = false
                self.lock.lock()
                self.entries = self.buffer // @Published assignment notifies
                self.lock.unlock()
            }
        }
    }
}
