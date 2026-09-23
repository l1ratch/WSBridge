# WSBridge

iOS Packet Tunnel Provider, переносящий механизм [tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy) (MIT) на iOS для SwiftGram — без ручной настройки прокси в приложении.

Ключевое отличие от десктопного оригинала: SwiftGram не знает о прокси и говорит с датацентрами Telegram напрямую, поэтому туннелю **не нужна** крипто-машина десктопа (secret, relay_init, реэнкрипция, fake_tls). Байт-поток клиента сплайсится в WebSocket почти как есть — по образцу CF-worker фолбэка апстрима.

## Фазы

- **Фаза 1 (сейчас)** — пустой PTP: `includedRoutes` только на IP датацентров Telegram, пакеты логируются и дропаются. Цель: проверить, что подпись через GBox (dev-серт + mobileprovision) принимает VPN-entitlement и вложенный `.appex`, и что трафик SwiftGram доходит до расширения. Телеметрия (число пакетов/байт/адреса) видна прямо в приложении по кнопке «Статистика туннеля» — Mac для логов не нужен.
- **Фаза 2** — lwIP/tun2socks: реконструкция TCP-потока из сырых пакетов.
- **Фаза 3** — WS-сплайсинг: парсинг 64-байтного init клиента (dc_idx, proto_tag), каскад фолбэков (CF-worker → ротационные CF-домены апстрима → прямой TCP), MsgSplitter для покадрового выравнивания MTProto-пакетов.

## Сборка

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project WSBridge.xcodeproj -scheme WSBridge -sdk iphoneos build
```

Либо CI: `.github/workflows/build.yml` собирает unsigned IPA при пуше в `main` (runner macos-15).

## Подпись (GBox)

Unsigned IPA подписывается своим dev-сертом (p12) + mobileprovision. Важно:

- Профиль должен покрывать **оба** bundle id: `com.l1ratch.WSBridge` (приложение) и `com.l1ratch.WSBridge.tunnel` (расширение).
- Wildcard-профиль (`com.l1ratch.*`) для расширения **не подойдёт**: entitlement `com.apple.developer.networking.networkextension` (packet-tunnel-provider) не выдаётся на wildcard App ID. Нужен явный App ID с включённой capability «Network Extensions» в Developer Portal.

## Структура

```
project.yml          — XcodeGen (вместо ручного .pbxproj)
App/                 — приложение-переключатель туннеля (SwiftUI)
Tunnel/              — Packet Tunnel Provider (.appex)
ref-tg-ws-proxy/     — клон апстрима (reference, не собирается)
```

Лицензия портируемой логики — MIT (Flowseal/tg-ws-proxy), атрибуция сохранена.
