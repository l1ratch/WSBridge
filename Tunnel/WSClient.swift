import Foundation

/// WS-клиент к kws-гейтвею Telegram. Каждый MTProto-пакет — отдельный WS-фрейм.
///
/// ponytail: один общий URLSession на все соединения — расширение имеет лимит ~15MB.
/// Каскад: ротационные CF-домены (работают) → kws{dc}.web.telegram.org (L4-блок).
final class WSClient {
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    private var task: URLSessionWebSocketTask?
    private var connected = false

    init() {}

    /// Подключается к kws-гейтвею. Пробует CF-домены, потом web.telegram.org.
    func connect(dc: Int, isTestDC: Bool, onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        let path = isTestDC ? "/apiws_test" : "/apiws"

        // Каскад: CF-домены → web.telegram.org
        let cfDomains = CFDomains.domains(dc: dc)
        let fallbackDomain = "kws\(dc).web.telegram.org"
        let allDomains = cfDomains + [fallbackDomain]

        tryConnect(domains: allDomains, path: path, index: 0, onMessage: onMessage, onClose: onClose)
    }

    private func tryConnect(domains: [String], path: String, index: Int, onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        guard index < domains.count else {
            NSLog("[WSBridge] WS: all domains failed")
            onClose()
            return
        }
        let domain = domains[index]
        guard let url = URL(string: "wss://\(domain)\(path)") else {
            tryConnect(domains: domains, path: path, index: index + 1, onMessage: onMessage, onClose: onClose)
            return
        }
        NSLog("[WSBridge] WS: trying \(domain)")
        let wsTask = Self.sharedSession.webSocketTask(with: url)
        task = wsTask
        wsTask.resume()

        // ponytail: guard от двойного advance (таймаут + failure)
        var advanced = false
        func advance() {
            guard !advanced else { return }
            advanced = true
            self.task = nil
            self.tryConnect(domains: domains, path: path, index: index + 1, onMessage: onMessage, onClose: onClose)
        }

        wsTask.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                advanced = true
                self.connected = true
                if case .data(let data) = message {
                    onMessage(data)
                }
                self.receiveLoop(onMessage: onMessage, onClose: onClose)
            case .failure:
                NSLog("[WSBridge] WS: \(domain) failed, trying next")
                advance()
            }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.connected, !advanced else { return }
            NSLog("[WSBridge] WS: \(domain) timed out, trying next")
            wsTask.cancel(with: .goingAway, reason: nil)
            advance()
        }
    }

    private func receiveLoop(onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .data(let data) = message {
                    onMessage(data)
                }
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
