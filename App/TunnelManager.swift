import Foundation
import NetworkExtension

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
        // ponytail: журнал из именованного UIPasteboard — расширение пишет туда
        // при каждом событии (throttle 2с). TCP-канал не работает: приложение
        // не может маршрутизировать свой трафик через собственный туннель.
        let pbName = UIPasteboard.Name("com.l1ratch.WSBridge.journal")
        if let pb = UIPasteboard(name: pbName, create: false),
           let text = pb.string, text.contains("ws_") {
            journalText = "журнал:\n" + text
        } else {
            journalText = "журнал недоступен: pasteboard пуст или не содержит событий"
        }
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
