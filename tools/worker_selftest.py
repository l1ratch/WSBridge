#自检 воркера: труба жива? Гоняем НЕ-TG трафик через /apiws?dst=...&port=80.
# Uso: python tools/worker_selftest.py [worker]
import sys
import os
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_gateway import ws_connect, ws_send, ws_recv  # noqa: E402

host = sys.argv[1] if len(sys.argv) > 1 else 'long-bush-c170.sm171105.workers.dev'
dst = sys.argv[2] if len(sys.argv) > 2 else 'example.com'
port = sys.argv[3] if len(sys.argv) > 3 else '80'
get_host = dst
ss = ws_connect(host, path=f'/apiws?dst={dst}&port={port}')
print(f'WS 101 OK -> {dst}:{port}')
t0 = time.time()
ws_send(ss, f'GET / HTTP/1.0\r\nHost: {get_host}\r\n\r\n'.encode())
ss.settimeout(10)
got = b''
try:
    while time.time() - t0 < 10 and len(got) < 300:
        op, payload, _ = ws_recv(ss)
        if op == 8:
            print(f'+{time.time()-t0:.2f}s CLOSE reason={payload[2:]!r}')
            break
        if op in (0, 1, 2) and payload:
            got += payload
            print(f'+{time.time()-t0:.2f}s frame {len(payload)}B')
except (TimeoutError, OSError) as e:
    print(f'read ended: {type(e).__name__}')
finally:
    ss.close()
head = got.split(b'\r\n')[0] if got else b''
print(f'VERDICT: pipe {"ALIVE" if got.startswith(b"HTTP/") else "DEAD"} head={head!r} total={len(got)}B')
