# Варианты рукопожатия с гейтвеем: Origin-заголовок / apiws_test.
# Uso: python tools/gw_origin.py [ip]
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
from gw_direct import req_pq_padded, find_respq  # noqa: E402

ip = sys.argv[1] if len(sys.argv) > 1 else '149.154.167.220'


def attempt(path, origin, dc=2, sni=None):
    sni = sni or f'kws{dc}.web.telegram.org'
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    s = socket.create_connection((ip, 443), timeout=8)
    ss = ctx.wrap_socket(s, server_hostname=sni)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (f'GET {path} HTTP/1.1\r\nHost: {sni}\r\nUpgrade: websocket\r\n'
           f'Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n'
           f'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n')
    if origin:
        req += f'Origin: {origin}\r\n'
    ss.sendall((req + '\r\n').encode())
    resp = b''
    ss.settimeout(8)
    try:
        while b'\r\n\r\n' not in resp:
            c = ss.recv(1024)
            if not c:
                return 'EOF'
            resp += c
    except TimeoutError:
        return 'HS-TIMEOUT'
    status = resp.split(b'\r\n')[0].decode(errors='replace')
    if '101' not in status:
        return f'WS {status}'
    init = make_init(dc, b'\xdd\xdd\xdd\xdd')
    enc = ctr(init[8:40], init[40:56])
    rev = init[8:56][::-1]
    dec = ctr(rev[:32], rev[32:])
    t0 = time.time()
    ws_send(ss, init)
    ws_send(ss, enc.update(req_pq_padded(os.urandom(16), whole_packet=False)))
    buf = b''
    try:
        while time.time() - t0 < 10:
            op, payload, _ = ws_recv(ss)
            if op == 8:
                return f'CLOSED reason={payload[2:]!r}'
            if op in (0, 1, 2) and payload:
                buf += dec.update(payload)
                if find_respq(buf):
                    return f'PASS resPQ +{time.time()-t0:.1f}s'
    except (TimeoutError, OSError):
        return f'SILENT plain={len(buf)}B'
    finally:
        try:
            ss.close()
        except Exception:
            pass
    return f'NO-RESPQ plain={len(buf)}B'


for path, origin in [
    ('/apiws', 'https://web.telegram.org'),
    ('/apiws', None),
    ('/apiws_test', None),
]:
    print(f'{ip} path={path} origin={origin}: {attempt(path, origin)}', flush=True)
print(f'{ip} sni=IP host=kws2: {attempt("/apiws", None, 2, sni=ip)}', flush=True)
