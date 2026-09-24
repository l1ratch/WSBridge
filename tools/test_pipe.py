# Энд-ту-энд проверка pipe-режима через CF worker: obfuscated init +
# req_pq_multi -> resPQ. Играет роль Telegram-клиента, гоняет байты
# тем же путём, что и PTP-расширение: WS-фреймы <-> worker <-> TCP DC.
# Uso: python tools/test_pipe.py [worker_host] [dc_ip]
import os, struct, sys, time

from test_gateway import ws_connect, ws_send, ws_recv, make_init
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

ZERO_64 = b'\x00' * 64
INTERMEDIATE = b'\xee\xee\xee\xee'
ABRIDGED = b'\xef\xef\xef\xef'  # прямой коннект Telegram-iOS = abridged!
RES_PQ = 0x05162463
REQ_PQ_MULTI = 0xBE7A8AF6


def ctr(key: bytes, iv: bytes):
    enc = Cipher(algorithms.AES(key), modes.CTR(iv)).encryptor()
    enc.update(ZERO_64)  # скип первых 64 байт keystream (obfuscated2)
    return enc


def build_req_pq(nonce: bytes, abridged: bool = True) -> bytes:
    body = struct.pack('<I', REQ_PQ_MULTI) + nonce
    msg_id = int(time.time() * 2**32) & ~3
    plain = struct.pack('<q', 0) + struct.pack('<q', msg_id)
    plain += struct.pack('<I', len(body)) + struct.pack('<I', 0) + body
    if abridged:
        # MTTcpConnection: quarterLength<=0x7e -> 1 байт, иначе 0x7f + 3 байта LE
        q = len(plain) // 4
        if q <= 0x7e:
            return bytes([q]) + plain
        return b'\x7f' + (q & 0xFFFFFF).to_bytes(3, 'little') + plain
    return struct.pack('<I', len(plain)) + plain  # intermediate-фрейм


def parse_frames_abridged(buf: bytes, nonce: bytes):
    off = 0
    while off < len(buf):
        b0 = buf[off]
        if b0 < 0x7f:
            ln = (b0 & 0x7f) * 4
            hdr = 1
        elif b0 == 0x7f:
            if len(buf) - off < 4:
                break
            ln = int.from_bytes(buf[off+1:off+4], 'little') * 4
            hdr = 4
        else:
            print(f'  abridged: bad marker 0x{b0:02x} at {off} — десинхрон?')
            return None
        if len(buf) - off - hdr < ln:
            break
        payload = buf[off + hdr: off + hdr + ln]
        off += hdr + ln
        if len(payload) < 4:
            print(f'  frame len={ln} payload too short: {payload.hex()}')
            continue
        (ctor,) = struct.unpack_from('<I', payload, 0)
        print(f'  frame len={ln} ctor=0x{ctor:08x}')
        if ctor == RES_PQ:
            return check_res_pq(payload, nonce)
    return None


def check_res_pq(payload: bytes, nonce: bytes):
    got_nonce = payload[4:20]
    server_nonce = payload[20:36]
    (pq_len,) = struct.unpack_from('<I', payload, 36)
    pq = payload[40:40 + pq_len]
    pqi = int.from_bytes(pq, 'big')
    a = b = None
    d = 3
    while d * d <= pqi:
        if pqi % d == 0:
            a, b = d, pqi // d
            break
        d += 2
    ok_nonce = got_nonce == nonce
    print(f'  resPQ: nonce_echo={"OK" if ok_nonce else "MISMATCH!"} '
          f'server_nonce={server_nonce.hex()} pq={pqi} '
          f'factors={a}x{b} {"OK" if a and a * b == pqi else "BAD"}')
    return ok_nonce and a is not None


def parse_frames(buf: bytes, nonce: bytes):
    """Разбирает intermediate-фреймы; возвращает True если нашли resPQ."""
    off = 0
    while len(buf) - off >= 4:
        (ln,) = struct.unpack_from('<I', buf, off)
        ln &= 0x7FFFFFFF
        if len(buf) - off - 4 < ln:
            break
        payload = buf[off + 4: off + 4 + ln]
        off += 4 + ln
        if len(payload) < 4:
            print(f'  frame len={ln} payload too short: {payload.hex()}')
            continue
        (ctor,) = struct.unpack_from('<I', payload, 0)
        print(f'  frame len={ln} ctor=0x{ctor:08x}')
        if ctor == RES_PQ:
            got_nonce = payload[4:20]
            server_nonce = payload[20:36]
            (pq_len,) = struct.unpack_from('<I', payload, 36)
            pq = payload[40:40 + pq_len]
            pqi = int.from_bytes(pq, 'big')
            # факторизуем pq (пробным делением — оно маленькое)
            a = b = None
            d = 3
            while d * d <= pqi:
                if pqi % d == 0:
                    a, b = d, pqi // d
                    break
                d += 2
            ok_nonce = got_nonce == nonce
            print(f'  resPQ: nonce_echo={"OK" if ok_nonce else "MISMATCH!"} '
                  f'server_nonce={server_nonce.hex()} pq={pqi} '
                  f'factors={a}x{b} {"OK" if a and a * b == pqi else "BAD"}')
            fp_off = 40 + pq_len
            (nf,) = struct.unpack_from('<I', payload, fp_off)
            fps = struct.unpack_from(f'<{nf}q', payload, fp_off + 4)
            print(f'  fingerprints({nf}): {[hex(f & (1 << 64) - 1) for f in fps]}')
            return ok_nonce and a is not None
    return None


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else 'long-bush-c170.sm171105.workers.dev'
    dst = sys.argv[2] if len(sys.argv) > 2 else '149.154.167.41'
    direct = 'direct' in sys.argv
    abridged = os.environ.get('TP_PROTO', 'abridged') == 'abridged'
    dc_idx = int(os.environ.get('TP_DC', '2'))

    init = make_init(dc_idx, ABRIDGED if abridged else INTERMEDIATE)
    nonce = os.urandom(16)
    # upstream: key/iv из init как есть; downstream: перевёрнутые
    enc_up = ctr(init[8:40], init[40:56])
    rev = init[8:56][::-1]
    dec_down = ctr(rev[:32], rev[32:])

    if direct:
        import socket
        print(f'DIRECT TCP {dst}:443 dc={dc_idx} proto=intermediate')
        ss = socket.create_connection((dst, 443), timeout=15)
        t0 = time.time()
        ss.sendall(init)
        ss.sendall(enc_up.update(build_req_pq(nonce, abridged)))
        print(f'+{time.time()-t0:.2f}s sent init+req_pq_multi')
        ss.settimeout(15)
        buf = b''
        done = None
        try:
            while time.time() - t0 < 15 and done is None:
                chunk = ss.recv(65536)
                if not chunk:
                    print('EOF from DC')
                    break
                buf += dec_down.update(chunk)
                print(f'+{time.time()-t0:.2f}s tcp={len(chunk)}B total_plain={len(buf)}B')
                done = (parse_frames_abridged(buf, nonce) if abridged
                        else parse_frames(buf, nonce))
        except (TimeoutError, OSError) as e:
            print(f'read ended: {type(e).__name__}: {e}')
        finally:
            ss.close()
        print('RESULT:', 'PASS — direct obfuscated handshake OK' if done else 'FAIL')
        return

    print(f'worker={host} dst={dst} dc={dc_idx} proto=intermediate')
    ss = ws_connect(host, path=f'/apiws?dst={dst}')
    print('WS handshake: 101 OK')
    t0 = time.time()

    combined = 'combined' in sys.argv
    padded = 'padded' in sys.argv
    if padded:
        # пересобираем init с padded-тегом (0xdd)
        abridged = False
        ss.close()
        init = make_init(dc_idx, b'\xdd\xdd\xdd\xdd')
        enc_up = ctr(init[8:40], init[40:56])
        rev = init[8:56][::-1]
        dec_down = ctr(rev[:32], rev[32:])
        ss = ws_connect(host, path=f'/apiws?dst={dst}')
        print('reconnected with PADDED tag')
        t0 = time.time()

    req = enc_up.update(build_req_pq(nonce, abridged))
    if combined:
        ws_send(ss, init + req)
        print(f'+{time.time()-t0:.2f}s sent init+req_pq in ONE frame ({64+len(req)}B)')
    else:
        ws_send(ss, init)
        ws_send(ss, req)
        print(f'+{time.time()-t0:.2f}s sent init 64B + req_pq separately')

    ss.settimeout(15)
    buf = b''
    done = None
    frames = 0
    try:
        while time.time() - t0 < 15 and done is None:
            opcode, payload, fin = ws_recv(ss)
            if opcode == 8:
                print(f'+{time.time()-t0:.2f}s CLOSE from worker')
                break
            if opcode not in (0, 1, 2) or not payload:
                continue
            frames += 1
            buf += dec_down.update(payload)
            print(f'+{time.time()-t0:.2f}s frame#{frames} ws={len(payload)}B '
                  f'total_plain={len(buf)}B')
            done = (parse_frames_abridged(buf, nonce) if abridged
                    else parse_frames(buf, nonce))
    except (TimeoutError, OSError) as e:
        print(f'read ended: {type(e).__name__}: {e}')
    finally:
        ss.close()

    print('RESULT:', 'PASS — pipe end-to-end OK' if done else 'FAIL')


if __name__ == '__main__':
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    main()
