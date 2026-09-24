import Foundation
import Network
import NetworkExtension

/// Читает журнал расширения TCP-соединением сквозь туннель. Nonisolated:
/// колбэки NWConnection приходят с произвольных потоков.
private enum JournalError: Error, CustomStringConvertible {
    case connFailed(String)
    case cancelled
    case timeout
    case empty
    var description: String {
        switch self {
        case .connFailed(let s): return "conn failed: \(s)"
        case .cancelled: return "cancelled"
        case .timeout: return "timeout 6s"
        case .empty: return "empty response"
        }
    }
}

private final class JournalReader {
    private let onResult: (Result<String, JournalError>) -> Void
    private var onDone: (() -> Void)?
    private var finished = false
    private var acc = Data()
    private var conn: NWConnection?

    init(onResult: @escaping (Result<String, JournalError>) -> Void) { self.onResult = onResult }

    func run(onDone: @escaping () -> Void) {
        self.onDone = onDone
        let conn = NWConnection(host: "198.18.0.3", port: 443, using: .tcp)
        self.conn = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.readMore()
            case .failed(let err): self?.finish(.failure(.connFailed(err.localizedDescription)))
            case .cancelled: self?.finish(.failure(.cancelled))
            default: break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.finish(.failure(.timeout))
        }
    }

    private func readMore() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.acc.append(data) }
            if error != nil || isComplete || data == nil {
                if self.acc.isEmpty {
                    self.finish(.failure(.empty))
                } else {
                    self.finish(.success(String(data: self.acc, encoding: .utf8) ?? "decode error"))
                }
            } else {
                self.readMore()
            }
        }
    }

    private func finish(_ result: Result<String, JournalError>) {
        if finished { return }
        finished = true
        conn?.cancel()
        conn = nil
        onResult(result)
        onDone?()
        onDone = nil
    }
}

// ponytail: глобальная ссылка для C-callback Darwin notifications
private var tunnelManagerRef: TunnelManager?
private let darwinEventNames = ["pkts", "accept", "init", "ws_sent", "ws_try", "ws_up", "ws_data", "ws_recv", "ws_close", "ws_fail"]

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

@MainActor
final class TunnelManager: ObservableObject {
    // ponytail: держим в одном месте; bundle id должен совпадать с project.yml и профилем подписи
    static let providerBundleId = "com.l1ratch.WSBridge.tunnel"

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var stats: String?
    @Published private(set) var journalText: String?
    @Published private(set) var lastPacketSignal: Date?
    @Published private(set) var lastEvent: String?
    @Published private(set) var lastEventTime: Date?
    @Published private(set) var lastAccept: Date?
    @Published var errorMessage: String?

    private var manager: NETunnelProviderManager?
    private var darwinObserver: CFRunLoopObserver?
    nonisolated(unsafe) private static var currentReader: JournalReader?

    init() {
        tunnelManagerRef = self
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let conn = note.object as? NEVPNConnection else { return }
            Task { @MainActor in self?.status = conn.status }
        }
        observeDarwinNotifications()
        Task { await reload() }
    }

    /// ponytail: Darwin notifications — единственный IPC без entitlements.
    /// Расширение постит события на каждом этапе; приложение слушает.
    private func observeDarwinNotifications() {
        for (index, event) in darwinEventNames.enumerated() {
            let name = "com.l1ratch.WSBridge.\(event)" as CFString
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                UnsafeRawPointer(bitPattern: index + 1),
                { _, observer, _, _, _ in
                    DispatchQueue.main.async {
                        guard let ref = tunnelManagerRef else { return }
                        let idx = (Int(bitPattern: observer) ?? 1) - 1
                        let eventName = darwinEventNames[safe: idx] ?? "unknown"
                        // ponytail: pkts и accept не должны перетирать WS-стадию —
                        // пробы SwiftGram плодят accept'ы без продолжения и прячут
                        // реальную стадию живой сессии.
                        if eventName == "pkts" {
                            ref.lastPacketSignal = Date()
                        } else if eventName == "accept" {
                            ref.lastAccept = Date()
                        } else {
                            ref.lastEvent = eventName
                            ref.lastEventTime = Date()
                        }
                        ref.updateStatsDisplay()
                    }
                },
                name,
                nil,
                .deliverImmediately
            )
        }
    }

    func updateStatsDisplay() {
        var parts: [String] = []
        if let event = lastEvent, let time = lastEventTime {
            let age = Int(Date().timeIntervalSince(time))
            parts.append("WS-стадия: \(event) (\(age)с назад)")
        } else {
            parts.append("WS-стадия: событий не было")
        }
        if let signal = lastPacketSignal {
            let age = Int(Date().timeIntervalSince(signal))
            parts.append(age < 3 ? "трафик течёт" : "последний трафик \(age)с назад")
        }
        if let accept = lastAccept {
            parts.append("accept: \(Int(Date().timeIntervalSince(accept)))с назад")
        }
        stats = parts.isEmpty ? "сигналов от расширения не было" : parts.joined(separator: "\n")
    }

    func fetchStats() {
        updateStatsDisplay()
        fetchJournal()
    }

    /// ponytail: журнал событий расширения читается TCP-соединением сквозь
    /// туннель (198.18.0.3:443) — Darwin-события приложение не получает в suspend.
    private func fetchJournal() {
        let reader = JournalReader { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let text): self?.journalText = "журнал:\n" + text
                case .failure(let err): self?.journalText = "журнал недоступен: \(err.description)"
                }
            }
        }
        // ponytail: держим ссылку, пока чтение не кончит (иначе reader умрёт
        // сразу после return — все колбэки держат его weakly).
        Self.currentReader = reader
        reader.run { Self.currentReader = nil }
    }

    func reload() async {
        manager = try? await NETunnelProviderManager.loadAllFromPreferences().first
        status = manager?.connection.status ?? .invalid
    }

    func toggle() async {
        errorMessage = nil
        do {
            let m: NETunnelProviderManager
            if let existing = manager {
                m = existing
            } else {
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = Self.providerBundleId
                proto.serverAddress = "WSBridge"
                let fresh = NETunnelProviderManager()
                fresh.protocolConfiguration = proto
                fresh.localizedDescription = "WSBridge"
                try await fresh.saveToPreferences()
                try await fresh.loadFromPreferences()
                m = fresh
                manager = m
            }
            // NEVPNErrorDomain error 2 (configurationDisabled): менеджер по умолчанию
            // сохраняется выключенным — включаем конфигурацию до старта туннеля.
            if !m.isEnabled {
                m.isEnabled = true
                try await m.saveToPreferences()
                try await m.loadFromPreferences()
            }
            switch m.connection.status {
            case .connected, .connecting, .reasserting:
                m.connection.stopVPNTunnel()
            default:
                try m.connection.startVPNTunnel()
            }
            status = m.connection.status
        } catch {
            NSLog("[WSBridge] toggle error: %@", error.localizedDescription)
            errorMessage = error.localizedDescription
            status = manager?.connection.status ?? .invalid
        }
    }
}
