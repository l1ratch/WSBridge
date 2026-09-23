import NetworkExtension

/// Фаза 1: пустой туннель-диагностика. Перехватывает только IP датацентров Telegram,
/// считает пакеты и дропает их (Telegram при включённом туннеле не работает — это
/// ожидаемо). Цель фазы — убедиться, что подпись с VPN-entitlement живёт в GBox
/// и трафик SwiftGram действительно доходит до расширения. Телеметрия отдаётся
/// в приложение через handleAppMessage — логи смотреть без Mac не нужно.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var packetCount: UInt64 = 0
    private var byteCount: UInt64 = 0
    private var seenHosts: Set<String> = []
    private var msgCount = 0
    private let startedAt = Date()

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // 198.18.0.0/15 — тестовый диапазон (RFC 2544), не конфликтует с реальными сетями
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.2"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = TelegramDCs.includedRoutes
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [128])
        ipv6.includedRoutes = TelegramDCs.includedRoutes6
        settings.ipv6Settings = ipv6

        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                NSLog("[WSBridge] setTunnelNetworkSettings failed: %@",
                      error.localizedDescription)
                completionHandler(error)
                return
            }
            NSLog("[WSBridge] tunnel started")
            self?.readLoop()
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        NSLog("[WSBridge] tunnel stopped (reason=%ld, pkts=%llu, bytes=%llu)",
              reason.rawValue, packetCount, byteCount)
        completionHandler()
    }

    /// Запрос телеметрии из приложения (NETunnelProviderSession.sendMessage).
    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        msgCount += 1
        // JSONSerialization не сериализует UInt64 — конвертируем в Int
        let payload: [String: Any] = [
            "pkts": Int(min(packetCount, UInt64(Int.max))),
            "bytes": Int(min(byteCount, UInt64(Int.max))),
            "uptime": Int(Date().timeIntervalSince(startedAt)),
            "msgs": msgCount,
            "hosts": Array(seenHosts).sorted(),
        ]
        completionHandler?(try? JSONSerialization.data(withJSONObject: payload))
    }

    private func readLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            self?.handle(packets: packets, protocols: protocols)
            self?.readLoop()
        }
    }

    private func handle(packets: [Data], protocols: [NSNumber]) {
        for (packet, family) in zip(packets, protocols) {
            packetCount += 1
            byteCount += UInt64(packet.count)
            let dst = family.intValue == AF_INET6 ? Self.ipv6Dst(packet) : Self.ipv4Dst(packet)
            if let dst, seenHosts.insert(dst).inserted {
                NSLog("[WSBridge] new dst %@ (pkts=%llu bytes=%llu)",
                      dst, packetCount, byteCount)
            }
        }
        // ponytail: пакеты дропаются (фаза 1). В фазе 2 здесь появится lwIP → WS-сплайсинг.
    }

    private static func ipv4Dst(_ packet: Data) -> String? {
        guard packet.count >= 20 else { return nil }
        return packet.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            return "\(b[16]).\(b[17]).\(b[18]).\(b[19])"
        }
    }

    private static func ipv6Dst(_ packet: Data) -> String? {
        guard packet.count >= 40 else { return nil }
        return packet.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            return (0..<8).map { i in
                String(format: "%02x%02x", b[16 + i * 2], b[17 + i * 2])
            }.joined(separator: ":")
        }
    }
}
