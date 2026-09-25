# Жив ли гейтвей .220 для других DC? (dc-тег в init варьируется)
# Uso: python tools/gw_dcs.py
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gw_direct import probe  # noqa: E402
import test_gateway as tgmod  # noqa: E402


def probe_dc(gw, sni_base, dc, variant='padded'):
    from test_pipe import ctr, build_req_pq
    import base64, socket, ssl, struct, time
    from test_gateway import ws_send, ws_recv, make_init
    from gw_direct import req_pq_padded, find_respq
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    sni_dc = 2 if dc == 203 else dc
    s = socket.create_connection((gw, 443), timeout=10)
    ss = ctx.wrap_socket(s, server_hostname=f'kws{sni_dc}.{sni_base}')
    key = base64.b64encode(os.urandom(16)).decode()
    ss.sendall((f'GET /apiws HTTP/1.1\r\nHost: kws{sni_dc}.{sni_base}\r\nUpgrade: websocket\r\n'
                f'Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n'
                f'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n').encode())
    resp = b''
    ss.settimeout(10)
    while b'\r\n\r\n' not in resp:
        c = ss.recv(1024)
        if not c:
            return 'EOF'
        resp += c
    if b'101' not in resp:
        return 'WS ' + resp.split(b'\r\n')[0].decode(errors='replace')[:60]
    tag = b'\xef\xef\xef\xef' if variant == 'abridged' else (
        b'\xee\xee\xee\xee' if variant == 'intermediate' else b'\xdd\xdd\xdd\xdd')
    init = make_init(dc, tag)
    enc = ctr(init[8:40], init[40:56])
    rev = init[8:56][::-1]
    dec = ctr(rev[:32], rev[32:])
    t0 = time.time()
    ws_send(ss, init)
    if variant == 'padded':
        req = req_pq_padded(os.urandom(16), whole_packet=False)
    elif variant == 'pad16':
        req = req_pq_padded(os.urandom(16), whole_packet=True)
    elif variant == 'intermediate':
        req = build_req_pq(os.urandom(16), abridged=False)
    else:
        req = build_req_pq(os.urandom(16), abridged=True)
    ws_send(ss, enc.update(req))
    buf = b''
    try:
        while time.time() - t0 < 12:
            op, payload, _ = ws_recv(ss)
            if op == 8:
                code = int.from_bytes(payload[:2], 'big') if len(payload) >= 2 else -1
                return f'CLOSED code={code} reason={payload[2:]!r}'
            if op in (0, 1, 2) and payload:
                buf += dec.update(payload)
                if find_respq(buf):
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
    dcs = [int(x) for x in sys.argv[2].split(',')] if len(sys.argv) > 2 else [1]
    variants = sys.argv[3].split(',') if len(sys.argv) > 3 else [
        'padded', 'pad16', 'intermediate', 'abridged']
    for dc in dcs:
        for v in variants:
            print(f'dc{dc} {v} via {gw}: '
                  f'{probe_dc(gw, "web.telegram.org", dc, v)}', flush=True)
