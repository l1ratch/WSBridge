import Foundation

/// Журнал событий расширения. Пишется файлом в общий App Groups контейнер
/// (ID групп берём из собственной подписи в рантайме — это группы продавца
/// из профиля подписи). Без UIKit: PTP-песочница режет pasteboard.
enum EventLog {
    private static var entries: [(String, Date)] = []
    private static let lock = NSLock()
    private static var lastWrite = Date.distantPast
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func append(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append((name, Date()))
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        let now = Date()
        if now.timeIntervalSince(lastWrite) >= 2.0 {
            lastWrite = now
            writeJournal()
        }
    }

    static func journal() -> String {
        lock.lock(); defer { lock.unlock() }
        return entries.map { "\(fmt.string(from: $0.1)) \($0.0)" }.joined(separator: "\n")
    }

    private static func writeJournal() {
        guard let url = SharedGroup.journalURL() else { return }
        try? journal().write(to: url, atomically: true, encoding: .utf8)
    }
}
