# Дамп сырого ответа гейтвей-ноды на три варианта init.
# Uso: python tools/raw_dump.py [ip]
import os
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_gateway import make_init  # noqa: E402
from test_pipe import ctr, build_req_pq, ABRIDGED, INTERMEDIATE  # noqa: E402

PADDED = b'\xdd\xdd\xdd\xdd'
ip = sys.argv[1] if len(sys.argv) > 1 else '149.154.167.99'


def req_padded(nonce):
    body = struct.pack('<I', 0xBE7A8AF6) + nonce
    msg_id = int(time.time() * 2**32) & ~3
    plain = struct.pack('<q', 0) + struct.pack('<q', msg_id)
    plain += struct.pack('<I', len(body)) + struct.pack('<I', 0) + body
    pad = (-len(plain)) % 16
    block = plain + os.urandom(pad)
    return struct.pack('<I', len(block)) + block


for name, tag, builder in [
    ('abridged', ABRIDGED, lambda n: build_req_pq(n, abridged=True)),
    ('intermediate', INTERMEDIATE, lambda n: build_req_pq(n, abridged=False)),
    ('padded', PADDED, req_padded),
]:
    s = socket.create_connection((ip, 443), timeout=10)
    init = make_init(2, tag)
    enc = ctr(init[8:40], init[40:56])
    rev = init[8:56][::-1]
    dec = ctr(rev[:32], rev[32:])
    s.sendall(init)
    s.sendall(enc.update(builder(os.urandom(16))))
    s.settimeout(8)
    resp = b''
    try:
        while len(resp) < 4096:
            c = s.recv(4096)
            if not c:
                break
            resp += c
    except (TimeoutError, OSError):
        pass
    plain = dec.update(resp)
    print(f'{name}: raw={len(resp)}B head={resp[:24].hex()}')
    print(f'   plain={len(plain)}B head={plain[:48].hex()}')
    if len(plain) >= 8:
        (ln,) = struct.unpack_from('<I', plain, 0)
        print(f'   as-intermediate: len={ln & 0x7FFFFFFF} '
              f'ctor=0x{struct.unpack_from("<I", plain, 4)[0]:08x}' if len(plain) >= 8 else '')
    s.close()
