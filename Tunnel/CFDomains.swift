import Foundation

/// Ротационные CF-домены из апстрима tg-ws-proxy (.github/cfproxy-domains.txt).
/// Декодированы функцией _dd() из config.py (shift cipher).
/// kws{dc}.{base_domain} фронтирует WS-гейтвей Telegram через Cloudflare.
enum CFDomains {
    // Декодированные домены из cfproxy-domains.txt (проверены DNS 23.09.2026)
    static let bases = [
        "pclead.co.uk",
        "offshor.co.uk",
        "cakeisalie.co.uk",
        "noskomnadzor.co.uk",
        "lovetrue.co.uk",
    ]

    /// Возвращает список доменов для WS-подключения: kws{dc}.{base}
    static func domains(dc: Int) -> [String] {
        bases.map { "kws\(dc).\($0)" }
    }
}
