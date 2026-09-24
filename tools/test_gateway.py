# Проверяет, отвечает ли kws-гейтвей на валидный MTProto init (формат десктопа).
# Строит init как _generate_relay_init из tg_ws_proxy.py, шлёт WS-фреймом, ждёт ответ.
import os, ssl, socket, struct, base64, sys, time

def make_init(dc_idx: int, proto_tag: bytes) -> bytes:
    RESERVED_FIRST = {0xEF}
    RESERVED_STARTS = [b'HEAD', b'POST', b'GET ', b'\xee\xee\xee\xee',
                       b'\xdd\xdd\xdd\xdd', b'\x16\x03\x01\x02']
    while True:
        rnd = bytearray(os.urandom(64))
        if rnd[0] in RESERVED_FIRST: continue
        if bytes(rnd[:4]) in RESERVED_STARTS: continue
        if rnd[4:8] == b'\x00\x00\x00\x00': continue
        break
    rnd = bytes(rnd)
    # AES-CTR через cryptography
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    key, iv = rnd[8:40], rnd[40:56]
    enc = Cipher(algorithms.AES(key), modes.CTR(iv)).encryptor()
    encrypted = enc.update(rnd)
    keystream = bytes(encrypted[i] ^ rnd[i] for i in range(56, 64))
    tail_plain = proto_tag + struct.pack('<h', dc_idx) + os.urandom(2)
    tail = bytes(a ^ b for a, b in zip(tail_plain, keystream))
    return rnd[:56] + tail

def ws_connect(host, path='/apiws', timeout=10):
    ctx = ssl.create_default_context()
    s = socket.create_connection((host, 443), timeout=timeout)
    ss = ctx.wrap_socket(s, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode()
    ss.sendall((f'GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n'
                f'Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n'
                f'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n').encode())
    resp = b''
    while b'\r\n\r\n' not in resp:
        c = ss.recv(1024)
        if not c: raise RuntimeError('EOF during handshake')
        resp += c
    status = resp.split(b'\r\n')[0].decode()
    if '101' not in status: raise RuntimeError(status)
    return ss

def ws_send(ss, data: bytes):
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    n = len(data)
    if n < 126:
        hdr = struct.pack('>BB', 0x82, 0x80 | n)
    elif n < 65536:
        hdr = struct.pack('>BBH', 0x82, 0x80 | 126, n)
    else:
        hdr = struct.pack('>BBQ', 0x82, 0x80 | 127, n)
    ss.sendall(hdr + mask + masked)

def recv_exact(ss, n):
    buf = b''
    while len(buf) < n:
        c = ss.recv(n - len(buf))
        if not c: raise EOFError('connection closed')
        buf += c
    return buf

def ws_recv(ss):
    hdr = recv_exact(ss, 2)
    opcode = hdr[0] & 0x0F
    fin = hdr[0] & 0x80
    length = hdr[1] & 0x7F
    if length == 126:
        length = struct.unpack('>H', recv_exact(ss, 2))[0]
    elif length == 127:
        length = struct.unpack('>Q', recv_exact(ss, 8))[0]
    payload = recv_exact(ss, length) if length else b''
    if hdr[1] & 0x80:
        m = recv_exact(ss, 4)
        payload = bytes(b ^ m[i % 4] for i, b in enumerate(payload))
    return opcode, payload, bool(fin)

if __name__ == '__main__':
    host = sys.argv[1] if len(sys.argv) > 1 else 'kws2.pclead.co.uk'
    dc = 2
    PADDED = b'\xdd\xdd\xdd\xdd'
    init = make_init(dc, PADDED)
    print(f'host={host} dc={dc} proto=padded_intermediate init[56:64]={init[56:64].hex()}')
    ss = ws_connect(host)
    print('WS handshake: 101 OK')
    t0 = time.time()
    ws_send(ss, init)
    print(f'sent init ({len(init)} bytes), waiting for reply...')
    ss.settimeout(20)
    try:
        while time.time() - t0 < 20:
            opcode, payload, fin = ws_recv(ss)
            print(f'+{time.time()-t0:.1f}s frame op={opcode} len={len(payload)} fin={fin} head={payload[:16].hex()}')
            if opcode == 8:
                print('CLOSE from gateway')
                break
            if opcode in (0, 1, 2) and payload:
                print('GATEWAY ANSWERED with data — protocol OK')
                break
    except socket.timeout:
        print('no reply in 20s — gateway silent')
    except EOFError as e:
        print(f'EOF: {e}')
    ss.close()
