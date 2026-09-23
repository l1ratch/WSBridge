import Foundation
import NetworkExtension

@MainActor
final class TunnelManager: ObservableObject {
    // ponytail: держим в одном месте; bundle id должен совпадать с project.yml и профилем подписи
    static let providerBundleId = "com.l1ratch.WSBridge.tunnel"

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var stats: String?
    @Published var errorMessage: String?

    private var manager: NETunnelProviderManager?

    init() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let conn = note.object as? NEVPNConnection else { return }
            Task { @MainActor in self?.status = conn.status }
        }
        Task { await reload() }
    }

    func reload() async {
        manager = try? await NETunnelProviderManager.loadAllFromPreferences().first
        status = manager?.connection.status ?? .invalid
    }

    func fetchStats() async {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        // sendProviderMessage имеет два оверлоада (async и completion) — вызываем
        // completion-вариант явно, чтобы компилятор не выбрал Void-версию.
        let data: Data? = await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(Data("stats".utf8)) { cont.resume(returning: $0) }
            } catch {
                NSLog("[WSBridge] stats error: %@", error.localizedDescription)
                cont.resume(returning: nil)
            }
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pkts = json["pkts"] as? UInt64,
              let bytes = json["bytes"] as? UInt64,
              let hosts = json["hosts"] as? [String] else { return }
        stats = "пакетов: \(pkts)\nбайт: \(bytes)" +
            (hosts.isEmpty ? "" : "\nадреса: " + hosts.joined(separator: ", "))
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
