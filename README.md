# WSBridge

Telegram на iOS без ручной настройки прокси. Порт десктопного [tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy) (MIT) в виде Packet Tunnel Provider для [SwiftGram](https://github.com/SwiftGram/SwiftGram).

Включил туннель — Telegram летает через WebSocket-мост. Выключил — обычный режим.

## Как это работает

SwiftGram не знает о прокси: он соединяется с датацентрами Telegram как обычно. Туннель перехватывает эти TCP-пакеты, восстанавливает поток через встроенный lwIP, парсит 64-байтный obfuscated2-init клиента (dc_idx, proto_tag) и сплайсит байты в WebSocket к гейтвеям Telegram (`kws*.web.telegram.org`) через Cloudflare.

Ключевое отличие от десктопного оригинала: SwiftGram говорит с DC напрямую (без MTProxy-секрета), поэтому туннелю **не нужна** крипто-машина десктопа (relay_init, реэнкрипция, fake_tls). Байт-поток клиента проходит почти как есть — по образцу CF-worker фолбэка апстрима.

### Транспорт

Каскад эндпоинтов с ротацией и кэшем здоровья:

1. **CF-фронты** (`kws{dc}.<rotating-domain>`) — Cloudflare фронтирует WS-гейтвей Telegram. Работает там, где прямые IP Telegram заблокированы.
2. **Прямые IP гейтвеев** (149.154.167.220, .205, .99, .174.100) — с Host-заголовком `kws{dc}.web.telegram.org` для vhost-маршрутизации.
3. **Нативный домен** `kws{dc}.web.telegram.org` — для сетей без отравленного DNS.

Мёртвые эндпоинты исключаются из каскада на 10 минут, живые очищаются. Round-robin старт распределяет ~12 параллельных соединений SwiftGram по разным фронтам.

## Сборка

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project WSBridge.xcodeproj -scheme WSBridge -sdk iphoneos build
```

CI (`.github/workflows/build.yml`) собирает unsigned IPA при пуше в `main` (runner macos-26, Xcode 26). IPA публикуется в GitHub Pages как [GBox-источник](https://l1ratch.github.io/WSBridge-iOS/) — добавь ссылку в GBox и ставь/обновляй прямо с телефона.

## Подпись

Unsigned IPA подписывается через GBox (или SideStore/AltStore) своим dev-сертом (p12) + mobileprovision.

- Профиль должен покрывать **оба** bundle id: `com.l1ratch.WSBridge` (приложение) и `com.l1ratch.WSBridge.tunnel` (расширение).
- Wildcard-профиль (`com.l1ratch.*`) для расширения **не подойдёт**: entitlement `com.apple.developer.networking.networkextension` (packet-tunnel-provider) не выдаётся на wildcard App ID. Нужен явный App ID с включённой capability «Network Extensions» в Developer Portal.
- Приложение не зависит от конкретного сертификата: bundle ID туннеля вычисляется динамически (`Bundle.main.bundleIdentifier + ".tunnel"`), App Groups не используются (IPC через loopback TCP и Darwin-уведомления).

## Структура

```
project.yml          — XcodeGen (вместо ручного .pbxproj)
App/                 — приложение-переключатель туннеля (SwiftUI)
Tunnel/              — Packet Tunnel Provider (.appex)
  lwip/              — встроенный lwIP (NO_SYS=1, однопоточный)
  arch/              — портирование lwIP под iOS
tools/               — диагностические скрипты (пробы, иконки)
worker-pipe.js       — CF Worker для pipe-режима (свой домен)
worker-pipe-p80.js   — то же, порт 80
```

## Лицензия

Портируемая логика — MIT ([Flowseal/tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy)), атрибуция сохранена.
