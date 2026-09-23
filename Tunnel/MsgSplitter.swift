import Foundation

/// Разбивает TCP-поток на отдельные MTProto-пакеты для WS-фреймов.
/// Ключи из init клиента (без secret — стандартная обфускация).
/// Fast-forward на 64 байта (init уже отправлен как первый фрейм).
final class MsgSplitter {
    private let cipher: AESCTR
    private let protoTag: UInt32
    private var cipherBuf = Data()
    private var plainBuf = Data()
    private var disabled = false

    private static let abridged: UInt32 = 0xEFEFEFEF
    private static let intermediate: UInt32 = 0xEEEEEEEE
    private static let paddedIntermediate: UInt32 = 0xDDDDDDDD

    init?(key: Data, iv: Data, protoTag: UInt32) {
        guard let cipher = AESCTR(key: key, iv: iv) else { return nil }
        cipher.fastForward(64) // skip init
        self.cipher = cipher
        self.protoTag = protoTag
    }

    /// Принимает шифртекст, возвращает массив шифртекст-пакетов для WS-фреймов.
    func split(_ chunk: Data) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        if disabled { return [chunk] }

        cipherBuf.append(chunk)
        if let plain = cipher.update(chunk) {
            plainBuf.append(plain)
        }

        var parts: [Data] = []
        var offset = 0
        let bufLen = cipherBuf.count

        while offset < bufLen {
            guard let packetLen = nextPacketLen(offset: offset, avail: bufLen - offset) else { break }
            if packetLen <= 0 {
                parts.append(cipherBuf.suffix(from: offset))
                offset = bufLen
                disabled = true
                break
            }
            parts.append(cipherBuf.subdata(in: offset..<offset + packetLen))
            offset += packetLen
        }

        if offset > 0 {
            cipherBuf.removeFirst(offset)
            plainBuf.removeFirst(offset)
        }
        return parts
    }

    /// Возвращает остаток буфера при закрытии соединения.
    func flush() -> [Data] {
        guard !cipherBuf.isEmpty else { return [] }
        let tail = cipherBuf
        cipherBuf.removeAll()
        plainBuf.removeAll()
        return [tail]
    }

    private func nextPacketLen(offset: Int, avail: Int) -> Int? {
        guard avail > 0 else { return nil }
        if protoTag == Self.abridged {
            return nextAbridgedLen(offset: offset, avail: avail)
        }
        if protoTag == Self.intermediate || protoTag == Self.paddedIntermediate {
            return nextIntermediateLen(offset: offset, avail: avail)
        }
        return 0
    }

    private func nextAbridgedLen(offset: Int, avail: Int) -> Int? {
        let first = plainBuf[plainBuf.startIndex + offset]
        var payloadLen: Int
        var headerLen: Int
        if first == 0x7F || first == 0xFF {
            if avail < 4 { return nil }
            let b1 = plainBuf[plainBuf.startIndex + offset + 1]
            let b2 = plainBuf[plainBuf.startIndex + offset + 2]
            let b3 = plainBuf[plainBuf.startIndex + offset + 3]
            payloadLen = (Int(b1) | (Int(b2) << 8) | (Int(b3) << 16)) * 4
            headerLen = 4
        } else {
            payloadLen = Int(first & 0x7F) * 4
            headerLen = 1
        }
        if payloadLen <= 0 { return 0 }
        let packetLen = headerLen + payloadLen
        if avail < packetLen { return nil }
        return packetLen
    }

    private func nextIntermediateLen(offset: Int, avail: Int) -> Int? {
        if avail < 4 { return nil }
        let base = plainBuf.startIndex + offset
        let payloadLen = (Int(plainBuf[base]) |
                         (Int(plainBuf[base + 1]) << 8) |
                         (Int(plainBuf[base + 2]) << 16) |
                         (Int(plainBuf[base + 3]) << 24)) & 0x7FFFFFFF
        if payloadLen <= 0 { return 0 }
        let packetLen = 4 + payloadLen
        if avail < packetLen { return nil }
        return packetLen
    }
}
