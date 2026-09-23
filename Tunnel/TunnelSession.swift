import Foundation

/// Оркестратор одного соединения: lwIP TCP ↔ WS к kws-гейтвею.
/// Парсит init, коннектится к kws{dc}, мостит байты через MsgSplitter.
final class TunnelSession {
    let connId: UInt32
    let dcIP: UInt32
    private let bridge: LWIPBridge
    private var ws: WSClient?
    private var splitter: MsgSplitter?
    private var initBuffer = Data()
    private var initParsed = false
    private var wsConnected = false

    init(connId: UInt32, dcIP: UInt32, bridge: LWIPBridge) {
        self.connId = connId
        self.dcIP = dcIP
        self.bridge = bridge
    }

    /// Данные от клиента (SwiftGram) через lwIP
    func handleData(_ data: Data) {
        if !initParsed {
            initBuffer.append(data)
            if initBuffer.count >= InitParser.handshakeLen {
                let init = initBuffer.prefix(InitParser.handshakeLen)
                if let parsed = InitParser.parse(Data(init)) {
                    initParsed = true
                    startWS(parsed: parsed)
                    // Остаток после init
                    let rest = initBuffer.suffix(from: InitParser.handshakeLen)
                    if !rest.isEmpty {
                        forwardToWS(rest)
                    }
                } else {
                    // Не MTProto init — дропаем
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

        splitter = MsgSplitter(key: parsed.key, iv: parsed.iv, protoTag: parsed.protoTag)

        let ws = WSClient()
        self.ws = ws
        ws.connect(dc: parsed.dcId, isTestDC: parsed.isTestDC, onMessage: { [weak self] data in
            self?.handleWSData(data)
        }, onClose: { [weak self] in
            self?.handleWSClose()
        })

        // Отправляем init как первый WS-фрейм
        let initData = initBuffer.prefix(InitParser.handshakeLen)
        ws.send(Data(initData))
        wsConnected = true
    }

    private func forwardToWS(_ data: Data) {
        guard wsConnected, let ws else { return }
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

    /// Данные от kws-гейтвея → клиенту через lwIP
    private func handleWSData(_ data: Data) {
        _ = bridge.write(connId: connId, data: data)
    }

    private func handleWSClose() {
        wsConnected = false
        bridge.close(connId: connId)
    }

    /// Соединение закрыто (клиент отключился или ошибка)
    func handleClose() {
        ws?.close()
        ws = nil
        wsConnected = false
    }
}
