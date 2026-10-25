import Foundation
import Observation

/// Begrenztes Diagnoseprotokoll (Ringpuffer) mit Textexport.
@Observable
final class DiagnosticLog {
    enum Kind: String, Sendable {
        case sent = "→"
        case received = "←"
        case info = "ℹ︎"
        case warning = "⚠︎"
        case error = "✖︎"
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let id: Int
        let date: Date
        let kind: Kind
        let text: String
    }

    let capacity: Int
    private(set) var entries: [Entry] = []
    private var nextID = 0
    /// Häufige Poll-Befehle füllen das Protokoll schnell. Standardmäßig werden sie nicht protokolliert.
    var logPolling = false

    init(capacity: Int = 400) {
        self.capacity = capacity
    }

    func add(_ kind: Kind, _ text: String) {
        let sanitized = text
            .replacingOccurrences(of: "\r", with: "␍")
            .replacingOccurrences(of: "\n", with: "␊")
        entries.append(Entry(id: nextID, date: Date(), kind: kind, text: String(sanitized.prefix(500))))
        nextID += 1
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func clear() {
        entries.removeAll()
    }

    func exportText(header: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var text = header + "\n\n"
        for entry in entries {
            text += "\(formatter.string(from: entry.date)) \(entry.kind.rawValue) \(entry.text)\n"
        }
        return text
    }
}

/// Misst Ereignisse pro Sekunde über ein gleitendes Zeitfenster (fester Ringpuffer).
nonisolated struct RateMeter {
    private var timestamps: [TimeInterval]
    private var index = 0
    private var count = 0
    let window: TimeInterval

    init(window: TimeInterval = 3, capacity: Int = 128) {
        self.window = window
        timestamps = Array(repeating: 0, count: capacity)
    }

    mutating func record(_ time: TimeInterval) {
        timestamps[index] = time
        index = (index + 1) % timestamps.count
        count = min(count + 1, timestamps.count)
    }

    func rate(now: TimeInterval) -> Double {
        guard count > 0 else { return 0 }
        var inWindow = 0
        var oldest = now
        for i in 0..<count {
            let t = timestamps[(index - 1 - i + timestamps.count) % timestamps.count]
            if now - t <= window {
                inWindow += 1
                oldest = min(oldest, t)
            }
        }
        guard inWindow > 1 else { return inWindow == 1 ? 1.0 / window : 0 }
        let span = max(now - oldest, 0.25)
        return Double(inWindow) / span
    }

    mutating func reset() {
        index = 0
        count = 0
    }
}
