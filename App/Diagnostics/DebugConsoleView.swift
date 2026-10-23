import SwiftUI

// The debug console surface: stats pane (folded over the log buffer),
// current-state pane (engine published state + last posted transition),
// and the log stream. One column; the log list scrolls and auto-follows
// the tail; the footer carries buffer fill and a copy-to-clipboard button.
struct DebugConsoleView: View {
    @ObservedObject var store: LogStore
    @ObservedObject var engine: SyncEngine

    init(engine: SyncEngine) {
        self.store = LogStore.shared
        self.engine = engine
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statsPane
            Divider()
            statePane
            Divider()
            logPane
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 520)
    }

    // MARK: - Stats (folded over the current buffer)

    private var stats: DiagnosticsStats { DiagnosticsStats(entries: store.entries) }

    private var statsPane: some View {
        let s = stats
        return Grid(horizontalSpacing: 14, verticalSpacing: 3) {
            ForEach(CommandName.allCases, id: \.rawValue) { name in
                GridRow {
                    Text(name.rawValue).monospacedCaption()
                    Text("\(s.commandCounts[name] ?? 0)").monospacedCaption()
                }
            }
            GridRow {
                Text("probe rounds").monospacedCaption()
                Text("\(s.probeRounds)").monospacedCaption()
            }
            GridRow {
                Text("busy drops").monospacedCaption()
                Text("\(s.busyDrops)").monospacedCaption().foregroundColor(s.busyDrops == 0 ? .secondary : .orange)
            }
            GridRow {
                Text("undecidable").monospacedCaption()
                Text("\(s.toggleUndecidables)").monospacedCaption().foregroundColor(s.toggleUndecidables == 0 ? .secondary : .orange)
            }
            GridRow {
                Text("setup issue").monospacedCaption()
                Text("\(s.setupIssues)").monospacedCaption().foregroundColor(s.setupIssues == 0 ? .secondary : .orange)
            }
        }
        .padding(10)
    }

    // MARK: - Current state

    private var statePane: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("STATE").font(.caption2).foregroundColor(.secondary)
            ForEach(SessionKind.allCases, id: \.rawValue) { kind in
                HStack {
                    Text(kind.displayName)
                    Spacer()
                    Text(stateText(kind: kind)).monospacedCaption()
                }
            }
            if engine.desiredState == nil {
                Text("no goal held").font(.caption2).foregroundColor(.secondary)
            } else {
                Text("goal: \(engine.desiredState!.state.rawValue)")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func stateText(kind: SessionKind) -> String {
        let observed = engine.snapshots[kind]
        let posted = stats.lastTransitions[kind]
        let observedText = observed.map { stateText($0) } ?? "—"
        return posted.map { "\(observedText)  → \($0.rawValue)" } ?? observedText
    }

    private func stateText(_ snapshot: SessionSnapshot) -> String {
        snapshot.inCall ? snapshot.state.rawValue : "no call"
    }

    // MARK: - Logs

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.entries) { entry in
                        LogRowView(entry: entry).id(entry.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onChange(of: store.entries) { entries in
                if let last = entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(store.entries.count)/\(LogStore.publishedCapacity)")
                .font(.caption2).foregroundColor(.secondary)
            Spacer()
            Button("Copy") { copyAll() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func copyAll() {
        let text = store.entries
            .map { entry in
                let line = "\(entry.time) \(entry.level.rawValue.uppercased()) [\(entry.category.rawValue)] \(entry.message)"
                return line
            }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// One log row: time + level on the left, category + message (+detail) right.
private struct LogRowView: View {
    let entry: LogEntry

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.time))
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
            Text(entry.level.rawValue.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundColor(Self.levelColor(entry.level))
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.message).font(.system(.caption, design: .monospaced))
            }
        }
    }

    private static func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}

extension Text {
    fileprivate func monospacedCaption() -> Text {
        font(.system(.caption, design: .monospaced))
    }
}
