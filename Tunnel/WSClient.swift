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
    private var firstRecv = false
    private var upPosted = false
    private static var sndErrLogged = 0
    private let tag: String

    init(tag: String = "") { self.tag = tag }

    private func post(_ name: String) {
        Self.postEvent(tag.isEmpty ? name : "\(tag):\(name)")
    }

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
            post("ws_fail")
            onClose()
            return
        }
        let domain = domains[index]
        guard let url = URL(string: "wss://\(domain)\(path)") else {
            tryConnect(domains: domains, path: path, index: index + 1, onMessage: onMessage, onClose: onClose)
            return
        }
        NSLog("[WSBridge] WS: trying \(domain)")
        post("ws_try:\(domain)")
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
            post("ws_fail:\(domain)")
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
                    if !self.upPosted {
                        self.upPosted = true
                        self.post("ws_up")
                    }
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
                post("ws_err:\(domain):\(error.localizedDescription)")
                state.delivered ? fail() : advance()
            }
        }

        // Таймер только на фазу коннекта. Доставленный init (delivered) гасит его —
        // раньше он убивал живое соединение, если DC отвечал дольше 10с.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            guard !state.delivered, state.claim() else { return }
            NSLog("[WSBridge] WS: \(domain) connect timed out, trying next")
            self.post("ws_timeout:\(domain)")
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

    /// Pipe-режим через СОБСТВЕННЫЙ CF worker пользователя: сырые байты в обе
    /// стороны, worker сам открывает TCP к dst:443 (DC). Ни гейтвея, ни сплиттера:
    /// init уходит частью потока, границы WS-фреймов не важны.
    func connectPipe(workerDomain: String, dst: String, onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        var comps = URLComponents()
        comps.scheme = "wss"
        comps.host = workerDomain
        comps.path = "/apiws"
        comps.queryItems = [URLQueryItem(name: "dst", value: dst)]
        guard let url = comps.url else {
            post("ws_badurl:\(workerDomain)")
            onClose()
            return
        }
        post("ws_try:\(workerDomain)")
        let wsTask = Self.sharedSession.webSocketTask(with: URLRequest(url: url))
        task = wsTask
        wsTask.resume()
        // Диагностика: pong = WS реально открыт (CF отвечает на ping сам).
        // ws_ping есть, ws_up нет — воркер жив, но завис его TCP к DC.
        wsTask.sendPing { [weak self] error in
            self?.post(error == nil ? "ws_ping" : "ws_pingerr")
        }
        // Watchdog первого байта: DC выборочно блэкхолит SYN с Cloudflare,
        // воркер без fail-fast висит молча, и клиент узнаёт об этом только
        // через 12с (app-watchdog). Рвём в 7с — приложение ретраится быстрее.
        DispatchQueue.global().asyncAfter(deadline: .now() + 7) { [weak self] in
            guard let self, self.task != nil, !self.firstRecv else { return }
            self.post("ws_slow")
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            onClose()
        }
        receiveLoop(onMessage: onMessage, onClose: onClose)
    }

    private func receiveLoop(onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if !firstRecv {
                    firstRecv = true
                    if !upPosted {
                        upPosted = true
                        post("ws_up")
                    }
                }
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
            if let error {
                NSLog("[WSBridge] WS send error: \(error.localizedDescription)")
                if Self.sndErrLogged < 3 {
                    Self.sndErrLogged += 1
                    self.post("ws_snderr:\(error.localizedDescription)")
                }
            }
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
