import NetworkExtension
import Foundation

/// Фаза 2: lwIP + WS-сплайсинг.
/// Перехватывает TCP к DC Telegram, восстанавливает поток через lwIP,
/// парсит init, коннектится к kws-гейтвею и мостит байты.
///
/// ponytail: lwIP с NO_SYS=1 однопоточный. ВСЕ операции (input, poll, write, close)
/// идут через одну serial-очередь. readPackets и WS-колбэки приходят с разных потоков.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let lwip = LWIPBridge()
    private var sessions: [UInt32: TunnelSession] = [:]
    private var packetCount: UInt64 = 0
    private var byteCount: UInt64 = 0
    private let startedAt = Date()
    private let lwipQueue = DispatchQueue(label: "com.l1ratch.WSBridge.lwip")

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
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
                NSLog("[WSBridge] setTunnelNetworkSettings failed: %@", error.localizedDescription)
                completionHandler(error)
                return
            }
            NSLog("[WSBridge] tunnel started")
            self?.setupLWIP()
            self?.readLoop()
            completionHandler(nil)
        }
    }

    private func setupLWIP() {
        lwip.start(
            output: { [weak self] data in
                self?.writePacket(data)
            },
            accept: { [weak self] connId, dcIP in
                self?.handleAccept(connId: connId, dcIP: dcIP)
            },
            recv: { [weak self] connId, data in
                self?.handleRecv(connId: connId, data: data)
            },
            close: { [weak self] connId in
                self?.handleClose(connId: connId)
            },
            sent: { _ in }
        )
    }

    private func writePacket(_ data: Data) {
        packetFlow.writePackets([data], withProtocols: [NSNumber(value: AF_INET)])
    }

    private func handleAccept(connId: UInt32, dcIP: UInt32) {
        NSLog("[WSBridge] accept conn \(connId) dc=\(dcIP)")
        let session = TunnelSession(connId: connId, dcIP: dcIP, bridge: lwip, queue: lwipQueue)
        sessions[connId] = session
    }

    private func handleRecv(connId: UInt32, data: Data) {
        sessions[connId]?.handleData(data)
    }

    private func handleClose(connId: UInt32) {
        sessions[connId]?.handleClose()
        sessions.removeValue(forKey: connId)
    }

    private func readLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.lwipQueue.async {
                for (packet, family) in zip(packets, protocols) {
                    guard family.intValue == AF_INET else { continue }
                    self.packetCount += 1
                    self.byteCount += UInt64(packet.count)
                    self.lwip.input(packet)
                }
                self.lwip.poll()
                if self.packetCount % 50 == 0 {
                    self.postDarwinNotification()
                }
            }
            self.readLoop()
        }
    }

    private func postDarwinNotification() {
        let name = "com.l1ratch.WSBridge.pkts" as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name),
            nil, nil, true
        )
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        NSLog("[WSBridge] tunnel stopped (reason=%ld, pkts=%llu, bytes=%llu)",
              reason.rawValue, packetCount, byteCount)
        lwipQueue.sync {
            for (_, session) in sessions { session.handleClose() }
            sessions.removeAll()
        }
        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        let text = "pkts=\(packetCount) bytes=\(byteCount) uptime=\(Int(Date().timeIntervalSince(startedAt)))s conns=\(sessions.count)"
        completionHandler?(text.data(using: .utf8))
    }
}
