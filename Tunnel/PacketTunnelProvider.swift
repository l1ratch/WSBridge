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
    private let journalServer = JournalServer()
    private var pollTimer: DispatchSourceTimer?
    private var ioTimer: DispatchSourceTimer?
    private var workerDomain: String?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.2"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = TelegramDCs.includedRoutes
        settings.ipv4Settings = ipv4
        // IPv6 НЕ анонсируем: lwIP у нас v4-only, анонсированный v6-маршрут
        // был чёрной дырой — SwiftGram ломился в v6 DC и висел до таймаута.
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                NSLog("[WSBridge] setTunnelNetworkSettings failed: %@", error.localizedDescription)
                completionHandler(error)
                return
            }
            NSLog("[WSBridge] tunnel started")
            let proto = self?.protocolConfiguration as? NETunnelProviderProtocol
            let wd = (proto?.providerConfiguration?["worker"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self?.workerDomain = (wd?.isEmpty == false) ? wd : nil
            EventLog.append("cfg:worker=\(self?.workerDomain ?? "-")")
            let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            EventLog.append("tunnel_start v\(ver)")
            self?.journalServer.start()
            self?.setupLWIP()
            self?.startTimers()
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
            close: { [weak self] connId, reason in
                self?.handleClose(connId: connId, reason: reason)
            },
            sent: { [weak self] connId in
                self?.sessions[connId]?.handleSent()
            }
        )
    }

    private func writePacket(_ data: Data) {
        EventLog.outPkts += 1
        packetFlow.writePackets([data], withProtocols: [NSNumber(value: AF_INET)])
    }

    /// ponytail: lwIP NO_SYS=1 требует периодического sys_check_timeouts.
    /// Раньше poll() крутился только на входящих пакетах — когда клиент затихал
    /// в ожидании ответа, ретрансмиты зависших сегментов не происходили никогда
    /// и сессия висела вечно (ровно картина «ws_recv есть, а ТГ стоит»).
    private func startTimers() {
        let poll = DispatchSource.makeTimerSource(queue: lwipQueue)
        poll.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        poll.setEventHandler { [weak self] in self?.lwip.poll() }
        poll.resume()
        pollTimer = poll

        let io = DispatchSource.makeTimerSource(queue: lwipQueue)
        io.schedule(deadline: .now() + 15, repeating: 15)
        io.setEventHandler { [weak self] in
            guard let self else { return }
            EventLog.append("io:in=\(self.packetCount) out=\(EventLog.outPkts) v6=\(EventLog.inV6) oth=\(EventLog.inOther) wd=\(EventLog.wsDown) wf=\(EventLog.writeFails) up=\(EventLog.upBytes) rx=\(EventLog.rxBytes) pend=\(EventLog.pendCur) sent=\(EventLog.sentCb) inmem=\(lwip_bridge_inmem_drops())")
            for (id, _) in self.sessions.sorted(by: { $0.key < $1.key }).prefix(2) {
                var st: UInt32 = 0, un: UInt32 = 0
                lwip_bridge_conn_stats(id, &st, &un)
                EventLog.append("c\(id):st=\(st) un=\(un)")
            }
        }
        io.resume()
        ioTimer = io
    }

    private func handleAccept(connId: UInt32, dcIP: UInt32) {
        NSLog("[WSBridge] accept conn \(connId) dc=\(dcIP)")
        postDarwinEvent("accept")
        let session = TunnelSession(connId: connId, dcIP: dcIP, workerDomain: workerDomain, bridge: lwip, queue: lwipQueue)
        sessions[connId] = session
    }

    private func handleRecv(connId: UInt32, data: Data) {
        sessions[connId]?.handleData(data)
    }

    private func handleClose(connId: UInt32, reason: Int32) {
        sessions[connId]?.handleClose(reason: reason)
        sessions.removeValue(forKey: connId)
    }

    private func readLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.lwipQueue.async {
                for (packet, family) in zip(packets, protocols) {
                    if family.intValue != AF_INET {
                        EventLog.inV6 += 1
                        continue
                    }
                    // Только TCP в lwIP; UDP (DNS мимо туннеля, QUIC) считаем и роняем.
                    guard packet.count > 9, packet[9] == 6 else {
                        EventLog.inOther += 1
                        continue
                    }
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
        postDarwinEvent("pkts")
    }

    private func postDarwinEvent(_ name: String) {
        let cfName = "com.l1ratch.WSBridge.\(name)" as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(cfName),
            nil, nil, true
        )
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        NSLog("[WSBridge] tunnel stopped (reason=%ld, pkts=%llu, bytes=%llu)",
              reason.rawValue, packetCount, byteCount)
        journalServer.stop()
        pollTimer?.cancel(); pollTimer = nil
        ioTimer?.cancel(); ioTimer = nil
        lwipQueue.sync {
            for (_, session) in sessions { session.handleClose(reason: 1) }
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
