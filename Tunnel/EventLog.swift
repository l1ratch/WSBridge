import Foundation
import UIKit

/// Журнал событий расширения. Приложение читает его через именованный
/// UIPasteboard — работает между процессами без entitlements, переживает
/// suspend, не показывает баннер «вставлено из» (в отличие от general).
enum EventLog {
    private static var entries: [(String, Date)] = []
    private static let lock = NSLock()
    private static var lastPasteboardWrite = Date.distantPast
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static let pbName = UIPasteboard.Name("com.l1ratch.WSBridge.journal")

    static func append(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append((name, Date()))
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        // Throttle: пишем в pasteboard не чаще раза в 2 секунды
        let now = Date()
        if now.timeIntervalSince(lastPasteboardWrite) >= 2.0 {
            lastPasteboardWrite = now
            writeJournal()
        }
    }

    static func journal() -> String {
        lock.lock(); defer { lock.unlock() }
        return entries.map { "\(fmt.string(from: $0.1)) \($0.0)" }.joined(separator: "\n")
    }

    private static func writeJournal() {
        let pb = UIPasteboard(name: pbName, create: true)
        pb?.string = journal()
    }
}
