# Говорит ли kws-нода «web»-протоколом: WS-кадр = чистое MTProto-сообщение
# (без init, без obfuscated2, без транспортного фрейминга)?
# Uso: python tools/gw_web.py [ip] [framed]
import base64
import os
import socket
import ssl
import struct
import sys
import time

ip = sys.argv[1] if len(sys.argv) > 1 else '149.154.167.99'
framed = len(sys.argv) > 2 and sys.argv[2] == 'framed'
sni = 'kws2.web.telegram.org'


def ws_frame(data: bytes) -> bytes:
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    n = len(data)
    if n < 126:
        hdr = struct.pack('>BB', 0x82, 0x80 | n)
    elif n < 65536:
        hdr = struct.pack('>BBH', 0x82, 0x80 | 126, n)
    else:
        hdr = struct.pack('>BBQ', 0x82, 0x80 | 127, n)
    return hdr + mask + masked


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = socket.create_connection((ip, 443), timeout=10)
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
        raise SystemExit('EOF handshake')
    resp += c
print('WS:', resp.split(b'\r\n')[0].decode())

nonce = os.urandom(16)
body = struct.pack('<I', 0xBE7A8AF6) + nonce
msg_id = int(time.time() * 2**32) & ~3
plain = struct.pack('<q', 0) + struct.pack('<q', msg_id)
plain += struct.pack('<I', len(body)) + struct.pack('<I', 0) + body
if framed:
    plain = struct.pack('<I', len(plain)) + plain
t0 = time.time()
ss.sendall(ws_frame(plain))

buf = b''
while time.time() - t0 < 10:
    hdr = b''
    try:
        while len(hdr) < 2:
            hdr += ss.recv(2 - len(hdr))
        op = hdr[0] & 0x0F
        ln = hdr[1] & 0x7F
        if ln == 126:
            ln = struct.unpack('>H', ss.recv(2))[0]
        elif ln == 127:
            ln = struct.unpack('>Q', ss.recv(8))[0]
        payload = b''
        while len(payload) < ln:
            c = ss.recv(ln - len(payload))
            if not c:
                break
            payload += c
    except (TimeoutError, OSError) as e:
        print(f'timeout/err: {type(e).__name__} buf={len(buf)}B')
        break
    if op == 8:
        code = int.from_bytes(payload[:2], 'big') if len(payload) >= 2 else -1
        print(f'CLOSED code={code} reason={payload[2:]!r}')
        break
    if payload:
        buf += payload
        print(f'+{time.time()-t0:.2f}s frame {len(payload)}B head={payload[:20].hex()}')
        off = 4 if not framed and len(buf) >= 8 else 0
        # web-ответ: чистое сообщение (auth_key=0 | msg_id | len | seq | ctor)
        for o in (0, 4):
            if len(buf) >= o + 24:
                (ctor,) = struct.unpack_from('<I', buf, o + 20)
                if ctor == 0x05162463:
                    print(f'PASS resPQ (ctor at +{o+20})')
                    raise SystemExit(0)
ss.close()
print('no resPQ')
