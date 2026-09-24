import Foundation

/// Журнал событий расширения. Приложение читает его через loopback TCP
/// (JournalServer, 127.0.0.1:51001) — работает всегда, без entitlements.
enum EventLog {
    private static var entries: [(String, Date)] = []
    private static let lock = NSLock()
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func append(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append((name, Date()))
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }

    static func journal() -> String {
        lock.lock(); defer { lock.unlock() }
        return entries.map { "\(fmt.string(from: $0.1)) \($0.0)" }.joined(separator: "\n")
    }
}
