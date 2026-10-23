import Foundation

// Pure aggregation over the captured window: the stats pane's whole
// world. Re-folded from `entries` on every console render, so counters
// are always exactly what the visible stream shows — no second store,
// no drift.
struct DiagnosticsStats: Equatable {
    // Accepted commands by trigger, in CommandName order.
    private(set) var commandCounts: [CommandName: Int] = [:]
    private(set) var busyDrops = 0
    private(set) var probeRounds = 0
    private(set) var toggleUndecidables = 0
    // Most recent transition per session kind (set at fold time).
    private(set) var lastTransitions: [SessionKind: MicState] = [:]
    // Adapter op outcomes per kind: probe/apply ok/fail + last durations.
    private(set) var adapterResults: [SessionKind: AdapterStats] = [:]
    private(set) var setupIssues = 0
    private(set) var lastError: LogEntry?

    struct AdapterStats: Equatable {
        var probeOK = 0
        var probeFail = 0
        var applyOK = 0
        var applyFail = 0
        var lastApplyMs: Int?
        var lastProbeMs: Int?
    }

    init(entries: [LogEntry]) {
        for entry in entries {
            if entry.level == .error {
                lastError = entry
            }
            guard let metric = entry.metric else { continue }
            switch metric {
            case .command(let name):
                commandCounts[name, default: 0] += 1
            case .busyDrop:
                busyDrops += 1
            case .probeRound:
                probeRounds += 1
            case .toggleUndecidable:
                toggleUndecidables += 1
            case .transition(let kind, let state):
                lastTransitions[kind] = state
            case .adapterResult(let kind, let op, let ok, let ms):
                var stats = adapterResults[kind] ?? AdapterStats()
                switch op {
                case .probe:
                    if ok { stats.probeOK += 1 } else { stats.probeFail += 1 }
                    stats.lastProbeMs = ms
                case .apply:
                    if ok { stats.applyOK += 1 } else { stats.applyFail += 1 }
                    stats.lastApplyMs = ms
                }
                adapterResults[kind] = stats
            case .setupIssue:
                setupIssues += 1
            }
        }
    }
}
