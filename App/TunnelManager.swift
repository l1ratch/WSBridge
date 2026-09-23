import Foundation
import NetworkExtension

// ponytail: глобальная ссылка для C-callback Darwin notifications
private var tunnelManagerRef: TunnelManager?

@MainActor
final class TunnelManager: ObservableObject {
    // ponytail: держим в одном месте; bundle id должен совпадать с project.yml и профилем подписи
    static let providerBundleId = "com.l1ratch.WSBridge.tunnel"

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var stats: String?
    @Published private(set) var lastPacketSignal: Date?
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
    /// Расширение постит сигнал каждые 50 пакетов; приложение слушает.
    private func observeDarwinNotifications() {
        let name = "com.l1ratch.WSBridge.pkts" as CFString
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    tunnelManagerRef?.lastPacketSignal = Date()
                    tunnelManagerRef?.updateStatsDisplay()
                }
            },
            name,
            nil,
            .deliverImmediately
        )
    }

    func updateStatsDisplay() {
        if let signal = lastPacketSignal {
            let age = Int(Date().timeIntervalSince(signal))
            stats = age < 3
                ? "трафик течёт (сигнал \(age)с назад)"
                : "последний сигнал \(age)с назад"
        } else {
            stats = "сигналов от расширения не было"
        }
    }

    func fetchStats() async {
        updateStatsDisplay()
    }

    func reload() async {
        manager = try? await NETunnelProviderManager.loadAllFromPreferences().first
        status = manager?.connection.status ?? .invalid
    }

    func fetchStats() async {
        // ponytail: sendProviderMessage не работает через GBox (IPC контекст не совпадает).
        // Читаем статистику из shared App Group container напрямую.
        guard let defaults = UserDefaults(suiteName: "group.com.l1ratch.WSBridge") else {
            stats = "нет App Group container"
            return
        }
        let pkts = defaults.integer(forKey: "pkts")
        let bytes = defaults.integer(forKey: "bytes")
        let uptime = defaults.integer(forKey: "uptime")
        let hosts = defaults.stringArray(forKey: "hosts") ?? []

        // Проверяем heartbeat-файл — расширение пишет его при старте туннеля
        var heartbeatInfo = ""
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.l1ratch.WSBridge"
        ) {
            let url = container.appendingPathComponent("heartbeat.txt")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                heartbeatInfo = "\nheartbeat: \(text)"
            } else {
                heartbeatInfo = "\nheartbeat: файл не найден (расширение не писало)"
            }
        }

        if pkts == 0 && bytes == 0 && uptime == 0 {
            stats = "container пуст — расширение ещё не писало (туннель активен?)" + heartbeatInfo
        } else {
            stats = "пакетов: \(pkts)\nбайт: \(bytes)\nuptime: \(uptime)с" +
                (hosts.isEmpty ? "\nадреса: (нет)" : "\nадреса: " + hosts.joined(separator: ", ")) +
                heartbeatInfo
        }
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
