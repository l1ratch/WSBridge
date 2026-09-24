import Foundation

/// Ротационные CF-домены из апстрима tg-ws-proxy (.github/cfproxy-domains.txt).
/// Декодированы функцией _dd() из config.py (shift cipher).
/// kws{dc}.{base_domain} фронтирует WS-гейтвей Telegram через Cloudflare.
enum CFDomains {
    // Полный встроенный список десктопа (_CFPROXY_ENC из config.py, decode _dd).
    // Раньше были только первые 5 — каскад не доходил до живых доменов.
    static let bases = [
        "pclead.co.uk",
        "offshor.co.uk",
        "cakeisalie.co.uk",
        "noskomnadzor.co.uk",
        "lovetrue.co.uk",
        "sorokdva.co.uk",
        "pyatdesyatdva.co.uk",
        "kartoshka.co.uk",
        "sorokodin.co.uk",
        "pyatdesyatodin.co.uk",
        "notelega.co.uk",
        "ebally.co.uk",
        "nebally.co.uk",
        "havegreatday.co.uk",
        "pomogite.co.uk",
        "fixtelega.co.uk",
        "sadnews.co.uk",
        "onedaychamp.co.uk",
        "stopblocking.co.uk",
        "nothingthere.co.uk",
    ]

    /// Возвращает список доменов для WS-подключения: kws{dc}.{base}
    static func domains(dc: Int) -> [String] {
        bases.map { "kws\(dc).\($0)" }
    }
}
