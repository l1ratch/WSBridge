import Foundation
import Security

/// Общий контейнер App Groups. Точные ID групп берём в рантайме из собственной
/// code signature (профиль подписи продавца уже содержит его группы), поэтому
/// хардкодить нечего. Работает и в приложении, и в расширении.
enum SharedGroup {
    static func groupIds() -> [String] {
        var staticCode: SecStaticCode?
        let url = Bundle.main.bundleURL as CFURL
        guard SecStaticCodeCreateWithPath(url, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, .init(rawValue: 2), &info) == errSecSuccess,
              let info else { return [] }
        let dict = info as NSDictionary
        let ents = dict[kSecCodeInfoEntitlementsDict as String] as? NSDictionary
        return ents?["com.apple.security.application-groups"] as? [String] ?? []
    }

    static func containerURL() -> URL? {
        for gid in groupIds() {
            if let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: gid) {
                return u
            }
        }
        return nil
    }

    static func journalURL() -> URL? {
        containerURL()?.appendingPathComponent("wsbridge-journal.txt")
    }
}
