import Foundation
import UIKit

/// Журнал событий расширения. Приложение читает его через UIPasteboard.general —
/// единственный pasteboard, видимый между процессами на iOS. Именованные
/// pasteboards на iOS не шарятся между процессами (в отличие от macOS).
enum EventLog {
    private static var entries: [(String, Date)] = []
    private static let lock = NSLock()
    private static var lastPasteboardWrite = Date.distantPast
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
        if now.timeIntervalSince(lastPasteboardWrite) >= 2.0 {
            lastPasteboardWrite = now
            UIPasteboard.general.string = journal()
        }
    }

    static func journal() -> String {
        lock.lock(); defer { lock.unlock() }
        return entries.map { "\(fmt.string(from: $0.1)) \($0.0)" }.joined(separator: "\n")
    }
}
