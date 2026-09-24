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

    // Счётчики io-строки журнала (пишутся с lwipQueue)
    static var outPkts: UInt64 = 0
    static var wsDown: UInt64 = 0
    static var writeFails: UInt64 = 0
    static var upBytes: UInt64 = 0
    static var rxBytes: UInt64 = 0
    static var pendCur: UInt64 = 0
    static var sentCb: UInt64 = 0
    static var inV4tcp: UInt64 = 0
    static var inV6: UInt64 = 0
    static var inOther: UInt64 = 0

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
