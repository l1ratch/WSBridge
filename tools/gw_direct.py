# Прямой probe WS-гейтвея Telegram (dc_redirects IP) с вариантами протокола.
# Uso: python tools/gw_direct.py [gw_ip] [sni_base] [variant]
# variant: full (default) | initonly | pad16 | abridged
import base64
import os
import socket
import ssl
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_gateway import ws_send, ws_recv, make_init  # noqa: E402
from test_pipe import ctr  # noqa: E402

PADDED = b'\xdd\xdd\xdd\xdd'
ABRIDGED = b'\xef\xef\xef\xef'
REQ_PQ_MULTI = 0xBE7A8AF6
RES_PQ = 0x05162463


def find_respq(buf: bytes) -> bool:
    off = 0
    while len(buf) - off >= 4:
        ln = struct.unpack_from('<I', buf, off)[0] & 0x7FFFFFFF
        if len(buf) - off - 4 < ln:
            return False
        if ln >= 4:
            (ctor,) = struct.unpack_from('<I', buf, off + 4)
            if ctor == RES_PQ:
                return True
        off += 4 + ln
    return False


def find_respq_ab(buf: bytes) -> bool:
    off = 0
    while off < len(buf):
        b0 = buf[off]
        if b0 < 0x7F:
            ln, hdr = (b0 & 0x7F) * 4, 1
        elif b0 == 0x7F:
            if len(buf) - off < 4:
                return False
            ln, hdr = int.from_bytes(buf[off + 1:off + 4], 'little') * 4, 4
        else:
            return False
        if len(buf) - off - hdr < ln:
            return False
        if ln >= 4:
            (ctor,) = struct.unpack_from('<I', buf, off + hdr)
            if ctor == RES_PQ:
                return True
        off += hdr + ln
    return False


def req_pq(nonce: bytes, abridged: bool) -> bytes:
    body = struct.pack('<I', REQ_PQ_MULTI) + nonce
    msg_id = int(time.time() * 2**32) & ~3
    plain = struct.pack('<q', 0) + struct.pack('<q', msg_id)
    plain += struct.pack('<I', len(body)) + struct.pack('<I', 0) + body
    if abridged:
        q = len(plain) // 4
        if q <= 0x7E:
            return bytes([q]) + plain
        return b'\x7f' + (q & 0xFFFFFF).to_bytes(3, 'little') + plain
    return struct.pack('<I', len(plain)) + plain


def req_pq_padded(nonce: bytes, whole_packet: bool) -> bytes:
    body = struct.pack('<I', REQ_PQ_MULTI) + nonce
    msg_id = int(time.time() * 2**32) & ~3
    plain = struct.pack('<q', 0) + struct.pack('<q', msg_id)
    plain += struct.pack('<I', len(body)) + struct.pack('<I', 0) + body
    if whole_packet:  # кратность 16 включая 4-байтовый length-заголовок
        pad = (-(len(plain) + 4)) % 16
    else:             # кратность 16 для payload+padding
        pad = (-len(plain)) % 16
    block = plain + os.urandom(pad)
    return struct.pack('<I', len(block)) + block


def probe(gw: str, sni: str, variant: str):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    s = socket.create_connection((gw, 443), timeout=10)
    ss = ctx.wrap_socket(s, server_hostname=sni)
    key = base64.b64encode(os.urandom(16)).decode()
    ss.sendall((f'GET /apiws HTTP/1.1\r\nHost: {sni}\r\nUpgrade: websocket\r\n'
                f'Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n'
                f'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n').encode())
    resp = b''
    ss.settimeout(10)
    while b'\r\n\r\n' not in resp:
        c = ss.recv(1024)
        if not c:
            return 'EOF during WS handshake'
        resp += c
    if b'101' not in resp:
        return 'WS ' + resp.split(b'\r\n')[0].decode(errors='replace')[:100]

    tag = ABRIDGED if variant == 'abridged' else PADDED
    init = make_init(2, tag)
    enc = ctr(init[8:40], init[40:56])
    rev = init[8:56][::-1]
    dec = ctr(rev[:32], rev[32:])
    t0 = time.time()
    ws_send(ss, init)
    if variant == 'initonly':
        pass
    elif variant == 'abridged':
        ws_send(ss, enc.update(req_pq(os.urandom(16), abridged=True)))
    elif variant == 'pad16':
        ws_send(ss, enc.update(req_pq_padded(os.urandom(16), whole_packet=True)))
    else:
        ws_send(ss, enc.update(req_pq_padded(os.urandom(16), whole_packet=False)))

    buf = b''
    try:
        while time.time() - t0 < 12:
            op, payload, _ = ws_recv(ss)
            if op == 8:
                code = int.from_bytes(payload[:2], 'big') if len(payload) >= 2 else -1
                reason = payload[2:]
                return f'CLOSED +{time.time()-t0:.1f}s code={code} reason={reason!r} plain={len(buf)}B'
            if op in (0, 1, 2) and payload:
                buf += dec.update(payload)
                found = find_respq_ab(buf) if variant == 'abridged' else find_respq(buf)
                if found:
                    return f'PASS resPQ +{time.time()-t0:.1f}s'
    except (TimeoutError, OSError) as e:
        return f'SILENT {type(e).__name__} plain={len(buf)}B'
    finally:
        try:
            ss.close()
        except Exception:
            pass
    return f'NO-RESPQ plain={len(buf)}B'


if __name__ == '__main__':
    gw = sys.argv[1] if len(sys.argv) > 1 else '149.154.167.220'
    base = sys.argv[2] if len(sys.argv) > 2 else 'web.telegram.org'
    variant = sys.argv[3] if len(sys.argv) > 3 else 'full'
    print(f'{gw} sni=kws2.{base} variant={variant}: {probe(gw, f"kws2.{base}", variant)}')
