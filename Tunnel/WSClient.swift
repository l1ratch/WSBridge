import Foundation

/// WS-клиент к kws-гейтвею Telegram. Каждый MTProto-пакет — отдельный WS-фрейм.
final class WSClient {
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var connected = false

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config)
    }

    /// Подключается к kws{dc}.web.telegram.org/apiws
    func connect(dc: Int, isTestDC: Bool, onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        let path = isTestDC ? "/apiws_test" : "/apiws"
        let domain = "kws\(dc).web.telegram.org"
        guard let url = URL(string: "wss://\(domain)\(path)") else {
            onClose()
            return
        }
        task = session.webSocketTask(with: url)
        task?.resume()
        connected = true
        receiveLoop(onMessage: onMessage, onClose: onClose)
    }

    private func receiveLoop(onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .data(let data):
                onMessage(data)
                self.receiveLoop(onMessage: onMessage, onClose: onClose)
            case .string:
                self.receiveLoop(onMessage: onMessage, onClose: onClose)
            case .failure:
                self.connected = false
                onClose()
            }
        }
    }

    func send(_ data: Data) {
        guard connected else { return }
        task?.send(.data(data)) { _ in }
    }

    func sendBatch(_ parts: [Data]) {
        for part in parts { send(part) }
    }

    func close() {
        connected = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}
