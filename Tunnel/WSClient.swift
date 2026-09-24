import Foundation

/// WS-клиент к kws-гейтвею Telegram. Каждый MTProto-пакет — отдельный WS-фрейм.
///
/// ponytail: один общий URLSession на все соединения — расширение имеет лимит ~15MB.
/// Каскад: ротационные CF-домены (работают) → kws{dc}.web.telegram.org (L4-блок).
final class WSClient {
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        // ponytail: request-timeout на WS-таске убивает сокет, если гейтвей молчит;
        // resource-timeout убивает сессию через N секунд. Каскадом управляет наш
        // собственный 10с-таймер, поэтому здесь значения заведомо щедрые.
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 86400
        return URLSession(configuration: config)
    }()

    private var task: URLSessionWebSocketTask?
    private var connected = false
    private var initFrame: Data?

    init() {}

    /// Подключается к kws-гейтвею. Пробует CF-домены, потом web.telegram.org.
    /// initFrame (64-байтовый MTProto init) шлётся первым фреймом на КАЖДОМ
    /// домене каскада — при failover старый task со своим init выбрасывается.
    func connect(dc: Int, isTestDC: Bool, initFrame: Data, onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        let path = isTestDC ? "/apiws_test" : "/apiws"
        self.initFrame = initFrame

        // Каскад: CF-домены → web.telegram.org
        let cfDomains = CFDomains.domains(dc: dc)
        let fallbackDomain = "kws\(dc).web.telegram.org"
        let allDomains = cfDomains + [fallbackDomain]

        tryConnect(domains: allDomains, path: path, index: 0, onMessage: onMessage, onClose: onClose)
    }

    private func tryConnect(domains: [String], path: String, index: Int, onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        guard index < domains.count else {
            NSLog("[WSBridge] WS: all domains failed")
            Self.postEvent("ws_fail")
            onClose()
            return
        }
        let domain = domains[index]
        guard let url = URL(string: "wss://\(domain)\(path)") else {
            tryConnect(domains: domains, path: path, index: index + 1, onMessage: onMessage, onClose: onClose)
            return
        }
        NSLog("[WSBridge] WS: trying \(domain)")
        Self.postEvent("ws_try")
        var request = URLRequest(url: url)
        request.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let wsTask = Self.sharedSession.webSocketTask(with: request)
        task = wsTask
        wsTask.resume()

        // Failover валиден только ДО доставки init: keystream клиента расходуется
        // один раз, на следующем домене init уже не примут. После ws_up любая
        // ошибка закрывает сессию — SwiftGram сам переподключится (новая сессия,
        // новый каскад). Десктоп делает так же: таймаут только на фазу коннекта.
        let state = TryState()
        func advance() {
            guard state.claim() else { return }
            self.task = nil
            self.tryConnect(domains: domains, path: path, index: index + 1, onMessage: onMessage, onClose: onClose)
        }
        func fail() {
            guard state.claim() else { return }
            self.task = nil
            Self.postEvent("ws_fail")
            onClose()
        }

        // Init — первым фреймом (URLSession буферизует до конца handshake).
        // ws_up = init в сокете; с этого момента каскадный таймер выключен.
        if let initFrame {
            wsTask.send(.data(initFrame)) { error in
                if let error {
                    NSLog("[WSBridge] WS init send error: \(error.localizedDescription)")
                } else {
                    state.delivered = true
                    Self.postEvent("ws_up")
                }
            }
        }

        wsTask.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                state.claim()
                self.connected = true
                if case .data(let data) = message {
                    onMessage(data)
                }
                self.receiveLoop(onMessage: onMessage, onClose: onClose)
            case .failure(let error):
                NSLog("[WSBridge] WS: \(domain) failed (\(error.localizedDescription)), next")
                state.delivered ? fail() : advance()
            }
        }

        // Таймер только на фазу коннекта. Доставленный init (delivered) гасит его —
        // раньше он убивал живое соединение, если DC отвечал дольше 10с.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            guard !state.delivered, state.claim() else { return }
            NSLog("[WSBridge] WS: \(domain) connect timed out, trying next")
            wsTask.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.tryConnect(domains: domains, path: path, index: index + 1, onMessage: onMessage, onClose: onClose)
        }
    }

    /// ponytail: NSLock вместо атомика — claim() должен быть именно once,
    /// колбэки send/receive/timer приходят с разных потоков.
    private final class TryState {
        private let lock = NSLock()
        private var claimed = false
        var delivered = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
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

    // ponytail: send сразу после resume() — URLSession сам буферизует до конца
    // handshake. Guard на connected был багом: init дропался, гейтвей молчал.
    func send(_ data: Data) {
        task?.send(.data(data)) { error in
            if let error { NSLog("[WSBridge] WS send error: \(error.localizedDescription)") }
        }
    }

    func sendBatch(_ parts: [Data]) {
        for part in parts { send(part) }
    }

    func close() {
        connected = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private static func postEvent(_ name: String) {
        EventLog.append(name)
        let cfName = "com.l1ratch.WSBridge.\(name)" as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(cfName),
            nil, nil, true
        )
    }
}
