import Foundation

/// Журнал событий расширения. Darwin-уведомления приложение не получает,
/// когда оно в suspend, поэтому журнал читается через диагностическое
/// TCP-соединение сквозь туннель (198.18.0.3:443).
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
