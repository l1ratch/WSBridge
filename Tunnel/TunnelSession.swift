import Foundation

/// Оркестратор одного соединения: lwIP TCP ↔ WS к kws-гейтвею.
/// Парсит init, коннектится к kws{dc}, мостит байты через MsgSplitter.
///
/// ponytail: ВСЕ lwIP-операции (write, close) идут через shared serial-очередь.
/// WS-колбэки приходят с потока URLSession — без очереди будет гонка.
class TunnelSession {
    let connId: UInt32
    let dcIP: UInt32
    let workerDomain: String?
    let bridge: LWIPBridge
    let queue: DispatchQueue
    private var ws: WSClient?
    private var splitter: MsgSplitter?
    private var initBuffer = Data()
    private var initParsed = false
    private var wsConnected = false
    private var dataSent = false
    private var bytesDown = 0
    private var headLogged = false
    private var upHeadLogged = false
    private var pending: Data?
    private let createdAt = Date()
    /// Сессия закрыта; слот connId мог уйти новому соединению — писать/закрывать нельзя.
    private var dead = false
    private static var wfailLogged = 0

    init(connId: UInt32, dcIP: UInt32, workerDomain: String?, bridge: LWIPBridge, queue: DispatchQueue) {
        self.connId = connId
        self.dcIP = dcIP
        self.workerDomain = workerDomain
        self.bridge = bridge
        self.queue = queue
    }

    /// Данные от клиента (SwiftGram) через lwIP. Вызывается на lwipQueue.
    func handleData(_ data: Data) {
        EventLog.rxBytes += UInt64(data.count)
        if !upHeadLogged {
            upHeadLogged = true
            let head = data.prefix(96).map { String(format: "%02x", $0) }.joined()
            postEvent("uphead:c\(connId):\(data.count):\(head)")
        }
        // Pipe-режим: собственный CF worker пользователя. Без init-парсинга и
        // сплиттера — сырой поток в WS, worker домостит его до DC:443.
        if workerDomain != nil {
            if !wsConnected { startPipe() }
            forwardToWS(data)
            return
        }
        if !initParsed {
            initBuffer.append(data)
            if initBuffer.count >= InitParser.handshakeLen {
                let initData = initBuffer.prefix(InitParser.handshakeLen)
                if let parsed = InitParser.parse(Data(initData)) {
                    initParsed = true
                    startWS(parsed: parsed)
                    let rest = initBuffer.suffix(from: InitParser.handshakeLen)
                    if !rest.isEmpty {
                        forwardToWS(rest)
                    }
                } else {
                    NSLog("[WSBridge] conn \(connId): not a valid MTProto init, dropping")
                    bridge.close(connId: connId)
                }
            }
        } else {
            forwardToWS(data)
        }
    }

    private func startWS(parsed: InitParser.ParsedInit) {
        NSLog("[WSBridge] conn \(connId): DC\(parsed.dcId) media=\(parsed.isMedia) test=\(parsed.isTestDC) proto=0x\(String(parsed.protoTag, radix: 16))")
        postEvent("init:conn\(connId):DC\(parsed.dcId)")

        splitter = MsgSplitter(key: parsed.key, iv: parsed.iv, protoTag: parsed.protoTag)

        // 64-байтовый init — первый WS-фрейм. WSClient шлёт его на каждом домене
        // каскада, поэтому передаём сюда, а не отдельным send() после connect().
        let initData = Data(initBuffer.prefix(InitParser.handshakeLen))

        let ws = WSClient(tag: "c\(connId)")
        self.ws = ws
        ws.connect(dc: parsed.dcId, isTestDC: parsed.isTestDC, initFrame: initData, onMessage: { [weak self] data in
            self?.handleWSData(data)
        }, onClose: { [weak self] in
            self?.handleWSClose()
        })

        wsConnected = true
        postEvent("ws_sent")
    }

    private func startPipe() {
        guard let workerDomain else { return }
        let dst = String(format: "%d.%d.%d.%d", (dcIP >> 24) & 255, (dcIP >> 16) & 255, (dcIP >> 8) & 255, dcIP & 255)
        postEvent("pipe:conn\(connId):\(dst)" + (dcIP == 0 ? ":raw=0" : ""))
        let ws = WSClient(tag: "c\(connId)")
        self.ws = ws
        let onMsg = { [weak self] (data: Data) in self?.handleWSData(data) }
        let onCls = { [weak self] in self?.handleWSClose() }
        // Поле «host:port» = прямое реле на VPS: сырой TCP, CF не участвует.
        let rest = workerDomain.split(separator: ":", maxSplits: 1)
        if rest.count == 2, let port = UInt16(rest[1]) {
            ws.connectRelay(host: String(rest[0]), port: port, dst: dst, onMessage: onMsg, onClose: onCls)
        } else {
            ws.connectPipe(workerDomain: workerDomain, dst: dst, onMessage: onMsg, onClose: onCls)
        }
        wsConnected = true
    }

    private func postEvent(_ name: String) {
        EventLog.append(name)
        let cfName = "com.l1ratch.WSBridge.\(name)" as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(cfName),
            nil, nil, true
        )
    }

    private func forwardToWS(_ data: Data) {
        guard wsConnected, let ws else { return }
        EventLog.upBytes += UInt64(data.count)
        // ws_data = клиентские данные (req_pq и т.д.) реально ушли на гейтвей.
        // Постится один раз на сессию — иначе спамит уведомлениями.
        if !dataSent {
            dataSent = true
            postEvent("ws_data:conn\(connId):\(data.count)B")
        }
        if let splitter {
            let parts = splitter.split(data)
            if parts.count == 1 {
                ws.send(parts[0])
            } else if parts.count > 1 {
                ws.sendBatch(parts)
            }
        } else {
            ws.send(data)
        }
    }

    /// Данные от kws-гейтвея → клиенту через lwIP.
    /// WS-колбэк приходит с потока URLSession — гоним через очередь.
    private func handleWSData(_ data: Data) {
        postEvent("ws_recv:c\(connId):\(data.count)B")
        if !headLogged {
            headLogged = true
            let head = data.prefix(16).map { String(format: "%02x", $0) }.joined()
            postEvent("ws_head:c\(connId):\(head)")
        }
        queue.async { [weak self] in
            // Сессия мертва — слот connId мог быть переиспользован новым
            // соединением; запоздалые байты отравят его шифрпоток.
            guard let self, !self.dead else { return }
            EventLog.wsDown += UInt64(data.count)
            _ = self.writeOrQueue(data)
        }
    }

    /// ponytail: tcp_write может вернуть ERR_MEM (окно/буфер забиты). Раньше байты
    /// просто дропались — дыра в шифрпотоке фатальна для MTProto. Теперь очередь:
    /// дожидается sent-колбэка и дописывает.
    private func writeOrQueue(_ data: Data) -> Bool {
        if pending != nil {
            pending?.append(data)
            EventLog.pendCur += UInt64(data.count)
            return false
        }
        if bridge.write(connId: connId, data: data) { return true }
        EventLog.writeFails += 1
        pending = data
        EventLog.pendCur += UInt64(data.count)
        if Self.wfailLogged < 3 {
            Self.wfailLogged += 1
            var e: Int32 = 0, w: UInt32 = 0, b: UInt32 = 0, u: UInt32 = 0
            lwip_bridge_snd_dbg(connId, &e, &w, &b, &u)
            postEvent("wfail:c\(connId):err=\(e) wnd=\(w) buf=\(b) un=\(u)")
        }
        return false
    }

    /// Освободилось место в send-буфере lwIP — дописываем очередь. Вызывается на lwipQueue.
    func handleSent() {
        EventLog.sentCb += 1
        guard let p = pending else { return }
        pending = nil
        if bridge.write(connId: connId, data: p) {
            EventLog.pendCur -= UInt64(p.count)
        } else {
            EventLog.writeFails += 1
            pending = p
        }
    }

    private func handleWSClose() {
        postEvent("ws_close:c\(connId)")
        queue.async { [weak self] in
            // Если сессию уже закрыл клиент (handleClose), слот мог уйти
            // новому соединению — bridge.close убил бы его.
            guard let self, !self.dead else { return }
            self.dead = true
            self.bridge.close(connId: self.connId)
        }
    }

    /// Соединение закрыто. reason: 0 = FIN клиента, 1 = stopTunnel,
    /// отрицательное = err_t lwIP (RST и т.п.). Вызывается на lwipQueue.
    func handleClose(reason: Int32 = 0) {
        dead = true
        let why = reason == 0 ? "fin" : "r\(reason)"
        postEvent("c\(connId):close:\(why):\(Int(Date().timeIntervalSince(createdAt)))s")
        ws?.close()
        ws = nil
        wsConnected = false
    }
}
