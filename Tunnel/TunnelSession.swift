import Foundation

/// Оркестратор одного соединения: lwIP TCP ↔ WS к kws-гейтвею.
/// Парсит init, коннектится к kws{dc}, мостит байты через MsgSplitter.
///
/// ponytail: ВСЕ lwIP-операции (write, close) идут через shared serial-очередь.
/// WS-колбэки приходят с потока URLSession — без очереди будет гонка.
class TunnelSession {
    let connId: UInt32
    let dcIP: UInt32
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

    init(connId: UInt32, dcIP: UInt32, bridge: LWIPBridge, queue: DispatchQueue) {
        self.connId = connId
        self.dcIP = dcIP
        self.bridge = bridge
        self.queue = queue
    }

    /// Данные от клиента (SwiftGram) через lwIP. Вызывается на lwipQueue.
    func handleData(_ data: Data) {
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

        let ws = WSClient()
        self.ws = ws
        ws.connect(dc: parsed.dcId, isTestDC: parsed.isTestDC, initFrame: initData, onMessage: { [weak self] data in
            self?.handleWSData(data)
        }, onClose: { [weak self] in
            self?.handleWSClose()
        })

        wsConnected = true
        postEvent("ws_sent")
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
        bytesDown += data.count
        postEvent("ws_recv:\(data.count)B")
        if !headLogged {
            headLogged = true
            let head = data.prefix(16).map { String(format: "%02x", $0) }.joined()
            postEvent("ws_head:\(head)")
        }
        queue.async { [weak self] in
            guard let self else { return }
            _ = self.bridge.write(connId: self.connId, data: data)
        }
    }

    private func handleWSClose() {
        postEvent("ws_close")
        queue.async { [weak self] in
            guard let self else { return }
            self.bridge.close(connId: self.connId)
        }
    }

    /// Соединение закрыто (клиент отключился или ошибка). Вызывается на lwipQueue.
    func handleClose() {
        ws?.close()
        ws = nil
        wsConnected = false
    }
}
