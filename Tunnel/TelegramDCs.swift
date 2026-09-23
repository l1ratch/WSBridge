import NetworkExtension

enum TelegramDCs {
    // ponytail: IPv4 из апстрима ref-tg-ws-proxy/proxy/utils.py (DC_DEFAULT_IPS + DC_TEST_IPS
    // + редирект 149.154.167.220). IPv6-адреса DC и диапазоны 91.108.x добавим в фазе 2,
    // когда сплайсинг начнёт их реально обслуживать — сейчас расширение пакеты только логирует.
    static let ipv4 = [
        "149.154.175.50",   // DC1
        "149.154.167.51",   // DC2
        "149.154.175.100",  // DC3
        "149.154.167.91",   // DC4
        "149.154.171.5",    // DC5
        "91.105.192.100",   // DC203 (media)
        "149.154.167.220",  // redirect DC2/DC4
        "149.154.175.10",   // test DC1
        "149.154.167.40",   // test DC2
        "149.154.175.117",  // test DC3
    ]

    static var includedRoutes: [NEIPv4Route] {
        ipv4.map { NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255") }
    }
}
