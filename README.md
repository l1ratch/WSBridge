# WSBridge-iOS

Telegram на iOS без ручной настройки прокси.

WSBridge — это VPN-туннель, который перехватывает трафик Telegram и перенаправляет его через WebSocket-соединение к серверам Telegram, минуя сетевые блокировки. Включил туннель — Telegram работает. Выключил — обычный режим. Настройка прокси внутри Telegram не нужна.

## Установка

Добавь источник в GBox / SideStore / AltStore:

```
https://l1ratch.github.io/WSBridge-iOS/source.json
```

Или скачай IPA из [Releases](https://github.com/l1ratch/WSBridge-iOS/releases) и подпиши своим dev-сертом.

## Как это работает

Приложение перехватывает TCP-трафик Telegram и перенаправляет его через WebSocket (TLS) к серверам Telegram (`kws*.web.telegram.org`), минуя сетевые блокировки. Настройка прокси внутри Telegram не нужна.

## Сборка

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project WSBridge.xcodeproj -scheme WSBridge -sdk iphoneos build
```

CI собирает unsigned IPA при пуше в `main`. IPA публикуется в GitHub Pages как источник — добавь ссылку в любой сайдлоадер (AltStore, SideStore и т.п.) и ставь/обновляй прямо с телефона.

## Подпись

Unsigned IPA подписывается через любой сайдлоадер своим dev-сертом + provisioning-профилем. Профиль должен покрывать оба bundle id (приложение и расширение) и включать capability «Network Extensions».

## Лицензия

MIT. Портируемая логика — [Flowseal/tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy) (MIT).
