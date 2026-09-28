import Foundation
import Network

/// Перехватывает DNS-запросы (UDP:53) из туннеля и форвардит их напрямую
/// на указанный DNS-сервер, минуя lwIP (который обрабатывает только TCP).
/// Ответы возвращаются обратно в туннель.
final class DNSForwarder {
    private let dnsServers: [String]
    private var sockets: [NWConnection] = []
    private let queue = DispatchQueue(label: "dns-forwarder")
    private let writePacket: (Data) -> Void

    init(dnsServers: [String], writePacket: @escaping (Data) -> Void) {
        self.dnsServers = dnsServers
        self.writePacket = writePacket
    }

    /// Проверяет, является ли пакет DNS-запросом (UDP:53).
    /// Возвращает true если пакет перехвачен и обработан.
    func tryHandle(_ packet: Data) -> Bool {
        // IP header: 20 bytes (без опций)
        guard packet.count > 28 else { return false }
        let ihl = Int(packet[0] & 0x0F) * 4
        let protocol_ = packet[9]
        guard protocol_ == 17 else { return false } // UDP

        // UDP header: src port (2), dst port (2), length (2), checksum (2)
        let udpStart = ihl
        guard packet.count > udpStart + 8 else { return false }
        let dstPort = Int(packet[udpStart + 2]) << 8 | Int(packet[udpStart + 3])
        guard dstPort == 53 else { return false }

        // DNS payload
        let dnsPayload = packet.subdata(in: (udpStart + 8)..<packet.count)
        guard !dnsPayload.isEmpty else { return false }

        // Форвардим на первый DNS-сервер
        guard let server = dnsServers.first else { return false }

        forward(dnsPayload: dnsPayload, originalPacket: packet, server: server)
        return true
    }

    private func forward(dnsPayload: Data, originalPacket: Data, server: String) {
        queue.async {
            let conn = NWConnection(
                host: NWEndpoint.Host(server),
                port: NWEndpoint.Port(integerLiteral: 53),
                using: .udp
            )
            self.sockets.append(conn)

            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    conn.send(content: dnsPayload, completion: .contentProcessed { _ in })
                    self?.receiveResponse(conn: conn, originalPacket: originalPacket)
                case .failed, .cancelled:
                    conn.cancel()
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
        }
    }

    private func receiveResponse(conn: NWConnection, originalPacket: Data) {
        conn.receiveMessage { [weak self] content, _, _, error in
            guard let self, let response = content, error == nil else {
                conn.cancel()
                return
            }
            self.wrapAndSend(dnsResponse: response, originalPacket: originalPacket)
            conn.cancel()
        }
    }

    /// Оборачивает DNS-ответ обратно в IP/UDP пакет (swap src/dst) и отправляет в туннель.
    private func wrapAndSend(dnsResponse: Data, originalPacket: Data) {
        let ihl = Int(originalPacket[0] & 0x0F) * 4
        let udpStart = ihl

        // Original: src IP (12-15), dst IP (16-19), src port, dst port
        let srcIP = originalPacket.subdata(in: 12..<16)
        let dstIP = originalPacket.subdata(in: 16..<20)
        let srcPort = originalPacket.subdata(in: udpStart..<udpStart + 2)
        let dstPort = originalPacket.subdata(in: udpStart + 2..<udpStart + 4)

        // Новый IP header
        var ipHeader = Data(count: 20)
        ipHeader[0] = 0x45 // IPv4, IHL=5
        ipHeader[1] = 0x00 // DSCP/ECN
        let totalLen = 20 + 8 + dnsResponse.count
        ipHeader[2] = UInt8(totalLen >> 8)
        ipHeader[3] = UInt8(totalLen & 0xFF)
        ipHeader[4] = 0x00; ipHeader[5] = 0x00 // ID
        ipHeader[6] = 0x00; ipHeader[7] = 0x00 // Flags/Fragment
        ipHeader[8] = 64 // TTL
        ipHeader[9] = 17 // UDP
        ipHeader[10] = 0x00; ipHeader[11] = 0x00 // Checksum (заполним позже)
        // Swap src/dst
        ipHeader.replaceSubrange(12..<16, with: dstIP)
        ipHeader.replaceSubrange(16..<20, with: srcIP)

        // IP checksum
        let ipChecksum = computeChecksum(ipHeader)
        ipHeader[10] = UInt8(ipChecksum >> 8)
        ipHeader[11] = UInt8(ipChecksum & 0xFF)

        // Новый UDP header
        var udpHeader = Data(count: 8)
        // Swap ports
        udpHeader.replaceSubrange(0..<2, with: dstPort)
        udpHeader.replaceSubrange(2..<4, with: srcPort)
        let udpLen = 8 + dnsResponse.count
        udpHeader[4] = UInt8(udpLen >> 8)
        udpHeader[5] = UInt8(udpLen & 0xFF)
        udpHeader[6] = 0x00; udpHeader[7] = 0x00 // Checksum (0 = не вычисляем для IPv4)

        var packet = ipHeader
        packet.append(udpHeader)
        packet.append(dnsResponse)

        writePacket(packet)
    }

    private func computeChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count - 1 {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if bytes.count % 2 == 1 {
            sum += UInt32(bytes[bytes.count - 1]) << 8
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return UInt16(~sum & 0xFFFF)
    }

    func stop() {
        queue.async {
            for conn in self.sockets { conn.cancel() }
            self.sockets.removeAll()
        }
    }
}
